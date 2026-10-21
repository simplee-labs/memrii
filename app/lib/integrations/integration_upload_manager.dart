import 'dart:async';

import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/automation/automation_policy.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/integrations/upload_types.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/time_utils.dart';

/// One connector's independent upload lane. Lanes drain concurrently (a
/// dedicated [IntegrationUploadManager._pumpLane] future each), but each lane
/// runs its own jobs strictly one at a time — so every destination only ever
/// sees a single upload, while a slow/503ing Omi Cloud lane never blocks a
/// fast HeyPocket lane. In-memory only (rebuilt by the next sweep after an
/// app-kill).
class _UploadLane {
  final List<UploadJob> manual = [];
  final List<UploadJob> auto = [];

  /// The job whose send() is currently awaited (null between jobs / paused).
  UploadJob? current;

  /// Re-entrancy guard — true while this lane's drain loop is running.
  bool draining = false;
  Completer<void>? drainSettled;

  /// Raised synchronously before any credential-transition await. It also holds
  /// while another settings session queues a transition for the same destination.
  int credentialTransitions = 0;
  Future<void> transitionTail = Future<void>.value();

  /// Set when the user disables this connector or its automatic sending mid-upload.
  /// The in-flight send() polls it (via the isCancelled callback) and bails at
  /// its next safe checkpoint; the drain loop then breaks. Reset once the worker
  /// fully exits, so a later re-enable uploads normally.
  bool cancelRequested = false;

  /// Key of a single in-flight job the user asked to cancel (vs [cancelRequested]
  /// which tears down the whole lane). The worker bails just that job and keeps
  /// draining the queue behind it. Cleared once the job exits.
  String? cancelCurrentKey;

  /// Completed / failed counts for this run. Held after the lane empties (so its
  /// notification line can read "8/8 done") until *every* lane is idle, then
  /// reset together so the aggregate total doesn't lurch.
  int done = 0;
  int failed = 0;

  /// Server-busy (503) backoff: lane paused until this time, then re-pumped.
  DateTime? busyUntil;

  bool get isEmpty => manual.isEmpty && auto.isEmpty;
  bool get isActive => current != null || !isEmpty;
  bool isPausedBusy(DateTime now) => busyUntil != null && busyUntil!.isAfter(now);
}

/// The upload engine: the one place recordings leave the archive for a destination.
///
/// It owns the per-connector lanes and the upload-status derivation, and it is the
/// bridge between the recording layer's model ([Conversation]) and the connector
/// boundary: connectors are handed [IntegrationRecording]s, never [Conversation]s, and
/// they are only ever asked to send through an [AuthorizedUpload] obtained from the
/// [SharingPolicy] — by an explicit user request ([uploadConversation], [uploadOne]) or,
/// for a connector the user switched to automatic sending, by the sweep
/// ([tryAutoUploadAll]).
///
/// All owner-/platform-facing concerns (wakelock, notifications, connectivity, UI
/// notify, passthrough conversion, the current batch list and pipeline-idle state) are
/// injected so this unit is testable without Flutter plugins.
class IntegrationUploadManager {
  IntegrationUploadManager({
    required List<Connector> connectors,
    required SharedPreferencesUtil prefs,
    required List<Batch> Function() batchesProvider,
    required bool Function() isDisposed,
    required bool Function() isPipelineIdle,
    required bool Function() isProcessing,
    required void Function() notifyUi,
    required void Function(String reason) acquireWake,
    required void Function(String reason) releaseWake,
    required void Function(String text) showUploadNotification,
    required void Function() settleNotification,
    required void Function(String message) setPendingSnack,
    required Future<bool> Function() checkOnWifi,
    required Future<void> Function(Conversation conversation) convertToPassthrough,
    List<MarkerConversation> Function()? markersProvider,
    SharingPolicy? policy,
    AutomationPolicy? automation,
    DateTime Function()? now,
  })  : _connectors = connectors,
        _prefs = prefs,
        _policy = policy ?? SharingPolicy(prefs, automation: automation),
        _now = now ?? DateTime.now,
        _batchesProvider = batchesProvider,
        _markersProvider = markersProvider ?? (() => const []),
        _ownerIsDisposed = isDisposed,
        _isPipelineIdle = isPipelineIdle,
        _isProcessing = isProcessing,
        _notifyUi = notifyUi,
        _acquireWake = acquireWake,
        _releaseWake = releaseWake,
        _showUploadNotification = showUploadNotification,
        _settleNotification = settleNotification,
        _setPendingSnack = setPendingSnack,
        _checkOnWifi = checkOnWifi,
        _convertToPassthrough = convertToPassthrough;

  final List<Connector> _connectors;
  final SharedPreferencesUtil _prefs;
  final SharingPolicy _policy;
  final DateTime Function() _now;
  final List<Batch> Function() _batchesProvider;
  final List<MarkerConversation> Function() _markersProvider;
  final bool Function() _ownerIsDisposed;
  bool _disposed = false;
  int _automationRevision = 0;
  bool _isDisposed() => _disposed || _ownerIsDisposed();
  final Map<String, Timer> _resumeTimers = {};

  /// Only the application owner calls this; disposing a page leaves lanes alive.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _resumeTimers.values) {
      timer.cancel();
    }
    _resumeTimers.clear();
    for (final lane in _lanes.values) {
      lane.cancelRequested = true;
      lane.manual.clear();
      lane.auto.clear();
    }
    _releaseWake('upload');
  }

  final bool Function() _isPipelineIdle;

  /// True while recordings on disk may still be renamed, merged or deleted
  /// (`RecordingsManager.recordingsUnsettled`: a processing run, or a clock-anchor pass
  /// outside one). Deliberately not [_isPipelineIdle]: that is the controller's screen
  /// state, and during a scheduled sync it still reads idle for the first seconds of
  /// processing — exactly the window [tryAutoUploadAll] must not sweep in.
  final bool Function() _isProcessing;

  /// Set when auto work was held back by [_isProcessing] — a sweep in
  /// [tryAutoUploadAll] or a queued job in [_pumpLane] — and cleared only by a sweep
  /// that actually runs. See [deferredSweepReady].
  bool _autoSweepDeferred = false;
  final Map<String, DateTime> _automaticRetryAt = {};
  final void Function() _notifyUi;
  final void Function(String reason) _acquireWake;
  final void Function(String reason) _releaseWake;
  final void Function(String text) _showUploadNotification;
  final void Function() _settleNotification;
  final void Function(String message) _setPendingSnack;
  final Future<bool> Function() _checkOnWifi;
  final Future<void> Function(Conversation conversation) _convertToPassthrough;

  /// The sharing policy grants go through — exposed so a future review screen and the
  /// tests address the same instance the sweep uses.
  SharingPolicy get sharingPolicy => _policy;
  AutomationPolicy get automation => _policy.automation;

  /// Upload keys of every recording with an upload in flight or queued.
  final Set<String> _syncingKeys = {};

  // Per-connector upload lanes, keyed by connector name. Each drains
  // concurrently but strictly sequentially within itself, so every server sees
  // one-at-a-time while a slow Omi Cloud lane can't block a fast HeyPocket lane. In
  // tap order within a lane (manual ahead of auto). In-memory only: on app-kill,
  // auto-eligible jobs self-heal via the next sweep; _syncingKeys gates dedup
  // against the in-flight job.
  final Map<String, _UploadLane> _lanes = {};
  _UploadLane _lane(String name) => _lanes.putIfAbsent(name, () => _UploadLane());
  bool get _anyLaneActive => _lanes.values.any((l) => l.isActive);

  // Fallback lane-pause window when a connector reports it's backing off but
  // exposes no concrete until-time (backingOffUntil == null). Omi Cloud drives
  // the real (exponential) window via backingOffUntil; this is only the default.
  static const Duration _busyBackoff = Duration(minutes: 5);
  static const Duration _automaticRetryDelay = Duration(seconds: 10);

  /// The connector-side view of [c] for status questions. No markers: nothing that
  /// answers a status question reads them, and this runs for every row on every repaint.
  IntegrationRecording _view(Conversation c) => IntegrationRecording.fromConversation(c);

  /// The view of [c] a candidate is built from: with the bookmarks inside it, which is
  /// what a reviewer would want to see next to the recording.
  IntegrationRecording _candidateView(Conversation c) {
    final path = c.file.path;
    final matching = [
      for (final m in _markersProvider())
        if (m.segment?.path == path) m
    ];
    final markers = [for (final m in matching) m.markerTime]..sort();
    return IntegrationRecording.fromConversation(c,
        markers: markers, hasPriorityMarker: matching.any((m) => m.isHighPriority));
  }

  /// True while at least one lane has an upload in flight (drives the
  /// processing-vs-upload notification arbitration in the controller).
  bool get hasInFlightUpload => _lanes.values.any((l) => l.current != null);

  /// Upload keys of every recording with an upload in flight or queued — drives
  /// the row/player "uploading" spinner. Derived from each lane's in-flight job
  /// plus its queues so it stays in lockstep with the workers.
  Set<String> get uploadingFiles {
    final keys = <String>{};
    void add(Conversation c) {
      final k = c.uploadKey;
      if (k != null) keys.add(k);
    }

    for (final lane in _lanes.values) {
      if (lane.current != null) add(lane.current!.conversation);
      for (final j in lane.manual) {
        add(j.conversation);
      }
      for (final j in lane.auto) {
        add(j.conversation);
      }
    }
    return keys;
  }

  /// Enqueues [grant]'s upload of [conversation] on [connector]'s lane, unless it's
  /// already in flight or already queued (dedup by [UploadJob.key]). Manual jobs drain
  /// ahead of auto within the lane. Does NOT start the lane — callers call
  /// [pumpAllLanes] after enqueuing a batch.
  void _enqueueUpload(Connector connector, Conversation conversation, AuthorizedUpload grant,
      {bool force = false, bool manual = false}) {
    final key = '${connector.name}_${conversation.file.path}';
    if (_syncingKeys.contains(key)) return; // currently uploading
    final lane = _lane(connector.name);
    if (lane.credentialTransitions > 0 || _isDisposed()) return;
    if (lane.manual.any((j) => j.key == key)) return;
    if (manual) {
      // A tap takes ownership of a condition-parked automatic job, with a user grant.
      lane.auto.removeWhere((j) => j.key == key);
    } else if (lane.auto.any((j) => j.key == key)) {
      return;
    }
    (manual ? lane.manual : lane.auto).add(UploadJob(connector, conversation, grant, force: force, manual: manual));
  }

  /// Drops every *queued* (not in-flight) job for [connectorName] from its lane
  /// and returns how many were removed. Shared by the disable-connector actions
  /// and the per-lane fail-fast path. Dropped jobs stay not-delivered: auto ones
  /// re-enqueue on the next sweep; manual ones revert to "Ready to Upload".
  int _purgeQueuedFor(String connectorName) {
    final lane = _lanes[connectorName];
    if (lane == null) return 0;
    final before = lane.manual.length + lane.auto.length;
    lane.manual.clear();
    lane.auto.clear();
    return before;
  }

  /// Kicks every lane that has work. Used by the auto sweep, the manual upload
  /// entry points, the connectivity listener (wifi returned), and busy resume.
  void pumpAllLanes() {
    for (final name in _lanes.keys.toList()) {
      unawaited(_pumpLane(name));
    }
  }

  /// Reclaim the shared notification after a sync/process notification finishes.
  void refreshNotification() {
    if (!_isDisposed() && hasInFlightUpload) _updateUploadNotification();
  }

  /// Holds the wakelock while an upload is actually **in flight** — auto or
  /// manual — so a backgrounded / swiped-away upload still completes; releases it
  /// between jobs and while a lane is merely queued or wifi-parked.
  void _refreshUploadHold() {
    if (_isDisposed()) {
      _releaseWake('upload');
      return;
    }
    final inFlight = _lanes.values.any((l) => l.current != null);
    if (inFlight) {
      _acquireWake('upload');
    } else {
      _releaseWake('upload');
    }
  }

  /// One connector's sequential upload worker. Drains its manual queue then its
  /// auto queue, one job at a time. Lanes run concurrently (a [_pumpLane] future
  /// each), so a slow/503ing Omi Cloud lane never blocks a fast HeyPocket lane; within a
  /// lane it's strictly one-at-a-time, so each server only ever sees one upload.
  /// Re-entrant calls for the same lane are coalesced by [lane.draining]. Parks
  /// (jobs stay queued) when automatic Wi-Fi-only is on and wifi is unavailable,
  /// and pauses on a 503 until the lane's backoff passes.
  Future<void> _pumpLane(String name) async {
    final lane = _lane(name);
    if (_isDisposed() || lane.credentialTransitions > 0 || lane.draining || lane.isPausedBusy(_now())) return;
    lane.draining = true;
    lane.drainSettled = Completer<void>();
    try {
      while (!_isDisposed() && !lane.isEmpty) {
        if (lane.cancelRequested) break; // user disabled this connector / its automatic sending
        // Auto work waits out processing exactly as the sweep that queued it does. A job
        // queued before a run began could otherwise start mid-run, on a recording the
        // stitch is about to fold into an earlier draft or the clock pass is about to
        // re-file — sending the device's wrong date, or failing on the path the rename
        // just emptied. Parked, not dropped: the controller's re-run of the held sweep
        // pumps the lane again once recordings settle, and the dequeue check below skips
        // any job whose recording has moved by then. Manual jobs drain first and never wait.
        if (lane.manual.isEmpty && _isProcessing()) {
          _autoSweepDeferred = true;
          break;
        }
        // Withdraw queued automation before checking conditions. Manual/review grants
        // retain their explicit authorization, including after entitlement loss.
        lane.auto.removeWhere((j) => !_policy.isStillAuthorized(j.connector, j.grant));
        if (lane.isEmpty) break;
        // Wifi gate before committing to an unattended job. Fail closed: if we can't confirm
        // wifi, park rather than upload over cellular. The connectivity listener
        // re-pumps on the next change. A lane that never leaves the phone is exempt.
        final next = lane.manual.isNotEmpty ? lane.manual.first : lane.auto.first;
        final rulesRevision = _automationRevision;
        if (_isAutomatic(next.grant) && automation.requiresWifi(next.connector)) {
          try {
            final onWifi = await _checkOnWifi();
            if (rulesRevision != _automationRevision) continue;
            if (!onWifi) {
              if (lane.manual.isNotEmpty) continue; // a tap arrived during the check
              break; // automatic work parked
            }
          } catch (e) {
            if (rulesRevision != _automationRevision) continue;
            Logger.error('_pumpLane($name): connectivity check failed ($e) — parking lane');
            if (lane.manual.isNotEmpty) continue;
            break;
          }
        }

        // Connectivity yields to cancellation, entitlement changes and processing.
        if (lane.isEmpty || lane.cancelRequested) break;
        if (lane.manual.isEmpty && _isProcessing()) {
          _autoSweepDeferred = true;
          break;
        }
        final job = lane.manual.isNotEmpty ? lane.manual.removeAt(0) : lane.auto.removeAt(0);
        final connector = job.connector;
        final conversation = job.conversation;
        final recording = _view(conversation);
        final retryKey = connector.retryKey(recording);

        // Re-validate at dequeue — state drifts between enqueue and run.
        if (!job.force && connector.hasDelivered(recording)) continue; // delivered by another path
        // Its source is gone since it was queued — renamed, folded into an earlier draft,
        // or deleted. Not a failure: uploading would throw, spend a retry and purge the
        // lane, and the next sweep queues the recording under whatever it is now.
        if (!connector.canSend(recording)) continue;
        // The user may have withdrawn what allowed this job while it waited — switched
        // automatic sending off, or rejected it in review. A user request never lapses.
        if (!_policy.isStillAuthorized(connector, job.grant)) continue;
        if (_isAutomatic(job.grant) && !automation.matchesRules(connector, _candidateView(conversation))) continue;
        if (!job.manual && connector.isBackingOff(recording)) continue; // auto honors backoff; manual overrides

        lane.current = job;
        _syncingKeys.add(job.key);
        // So a re-file leaves this recording alone until the upload is done — Omi's
        // progress is recorded under the path it started with (promoteSessionToDate).
        RecordingsManager.noteUploadStarted(conversation.file);
        _refreshUploadHold(); // hold the wakelock while this upload is in flight
        // Persist an up-front failure marker so an app-kill mid-upload reads
        // "failed" rather than reverting to "pending". Cleared by send() on success.
        unawaited(_prefs.setAutoUploadLastFailureAt(retryKey));
        _updateUploadNotification();
        if (!_isDisposed()) _notifyUi();

        bool delivered = false;
        bool busy = false;
        // True when the user cancelled THIS job — either a whole-lane cancel
        // (cancelRequested) or a single-job cancel targeting this one.
        bool jobCancelled() =>
            _isDisposed() ||
            lane.cancelRequested ||
            lane.cancelCurrentKey == job.key ||
            (_isAutomatic(job.grant) && !_policy.isStillAuthorized(connector, job.grant));
        try {
          await connector.send(job.grant, onProgress: _notifyChunkProgress, isCancelled: jobCancelled);
          if (connector.hasDelivered(recording)) {
            delivered = true;
            _policy.noteDelivered(job.grant);
            automation.noteDelivered(connector, recording);
            if (_prefs.passthroughMode) await _convertToPassthrough(conversation);
          } else if (jobCancelled()) {
            // Cancelled mid-upload (connector/automatic sending turned off, or a
            // single in-flight cancel). Not a failure: clear the up-front failure
            // marker so it reverts to pending/ready rather than showing failed.
            // Awaited (not fire-and-forget) so it lands before the UI re-reads the
            // state. Any queued jobs were already dropped by the cancel call.
            await _prefs.clearAutoUploadRetry(retryKey);
            if (_isAutomatic(job.grant) &&
                lane.credentialTransitions == 0 &&
                !lane.cancelRequested &&
                automation.requiresWifi(connector)) {
              _requestRetrySweep(name, Duration.zero);
            }
          } else if (connector.isBackingOff(recording)) {
            // Server busy (503/502/504): pause the whole lane and resume this
            // recording first once its backoff passes. Use the connector's real
            // (exponential) backoff time so the lane wakes — and the "retry HH:MM"
            // label reads — when the recording is actually eligible again, not a
            // fixed 5 min. Not a failure — don't spend retries.
            busy = true;
            lane.busyUntil = connector.backingOffUntil(recording) ?? _now().add(_busyBackoff);
            (job.manual ? lane.manual : lane.auto).insert(0, job);
            _scheduleLaneResume(name);
          } else if (job.manual) {
            // The user already authorized this transfer. A server-side pending job
            // (notably a chunked Omi job) needs transport continuation, not rediscovery.
            busy = true;
            await _prefs.clearAutoUploadRetry(retryKey);
            lane.busyUntil = _now().add(_busyBackoff);
            lane.manual.insert(0, job);
            _scheduleLaneResume(name);
          } else {
            // Pending server jobs retain their connector-side job IDs. Ask the
            // owner for a fresh archive/authorization sweep before reattaching.
            _requestRetrySweep(name, _busyBackoff);
          }
        } catch (e) {
          if (jobCancelled()) {
            // Aborted by a user cancel (connector/automatic sending off, or single
            // in-flight cancel) — not a failure: don't spend the retry budget or
            // count it as failed.
            await _prefs.clearAutoUploadRetry(retryKey);
            if (_isAutomatic(job.grant) &&
                lane.credentialTransitions == 0 &&
                !lane.cancelRequested &&
                automation.requiresWifi(connector)) {
              _requestRetrySweep(name, Duration.zero);
            }
            Logger.debug('Upload cancelled mid-flight (${connector.name})');
            continue; // finally clears the per-job flag; loop continues or breaks
          }
          // Only auto jobs spend the retry budget; a manual failure just stamps
          // the timestamp (surfaced as "failed" via _connectorState).
          if (!job.manual) await _prefs.incrementAutoUploadRetry(retryKey);
          unawaited(_prefs.setAutoUploadLastFailureAt(retryKey));
          lane.failed++;
          final credentialMessage = connector.credentialFailureMessage(e);
          if (credentialMessage != null) {
            _setPendingSnack(credentialMessage);
          } else {
            Logger.error('Upload failed (${connector.name}): $e');
          }
          // Fail fast for this lane: a failure usually means the connector/server
          // is unhealthy, so drop its remaining queued jobs instead of hammering it.
          // Other lanes are untouched. Dropped jobs aren't lost (auto re-enqueues on
          // the next sweep; manual reverts to "Ready to Upload").
          final retryAutomatic = !job.manual || lane.auto.isNotEmpty;
          final dropped = _purgeQueuedFor(connector.name);
          if (retryAutomatic) _requestRetrySweep(name, _automaticRetryDelay);
          if (dropped > 0) {
            Logger.debug('Upload: ${connector.name} failed — dropped $dropped remaining queued job(s)');
          }
        } finally {
          lane.current = null;
          _syncingKeys.remove(job.key);
          RecordingsManager.noteUploadFinished(conversation.file);
          // A single-job cancel targeted this job; clear it so the next job in the
          // queue isn't affected. (A whole-lane cancelRequested is reset only once
          // the worker exits, in the outer finally.)
          if (lane.cancelCurrentKey == job.key) lane.cancelCurrentKey = null;
          if (delivered) lane.done++;
          _refreshUploadHold(); // release the in-flight hold (re-acquired by the next job)
          if (!_isDisposed()) {
            _updateUploadNotification();
            _notifyUi();
          }
        }

        if (busy) break; // lane paused; a timer re-pumps it after the backoff
        if (lane.cancelRequested) break; // whole-lane cancel — stop (queues purged)
        // A single-job cancel (cancelCurrentKey) does NOT break: keep draining the
        // queue behind the cancelled job.
      }
    } finally {
      lane.draining = false;
      lane.drainSettled!.complete();
      lane.drainSettled = null;
      // The cancel has been honored for this drain; clear it so a later re-enable
      // (and its re-enqueued jobs) uploads normally.
      lane.cancelRequested = false;
    }

    _finalizeIfAllIdle();
  }

  /// Schedules a re-pump of [name]'s lane once its 503 backoff elapses.
  void _scheduleLaneResume(String name) {
    final until = _lanes[name]?.busyUntil;
    if (until == null) return;
    final delay = until.difference(_now());
    _resumeTimers.remove(name)?.cancel();
    _resumeTimers[name] = Timer(delay.isNegative ? Duration.zero : delay + const Duration(seconds: 1), () {
      _resumeTimers.remove(name);
      if (!_isDisposed()) unawaited(_pumpLane(name));
    });
  }

  /// Once no lane has work in flight or queued, reset the per-run counters
  /// together (so the aggregate total doesn't lurch as one lane finishes before
  /// another) and settle the notification back to idle.
  void _finalizeIfAllIdle() {
    if (_isDisposed() || _anyLaneActive) return;
    final hadProgress = _lanes.values.any((l) => l.done > 0 || l.failed > 0);
    for (final l in _lanes.values) {
      l.done = 0;
      l.failed = 0;
      l.busyUntil = null;
    }
    if (hadProgress && _isPipelineIdle()) _settleNotification();
  }

  /// Composes and pushes the aggregated upload notification: a one-line summary
  /// (shown collapsed) followed by a per-active-connector line (shown expanded
  /// via the native BigTextStyle). Only while the sync/process pipeline is idle
  /// (it owns the notification when active). Android-only (no-ops on iOS).
  void _updateUploadNotification() {
    if (!_isPipelineIdle()) return;

    int totalDone = 0, total = 0, totalFailed = 0;
    final lines = <String>[];
    for (final entry in _lanes.entries) {
      final lane = entry.value;
      final remaining = lane.manual.length + lane.auto.length + (lane.current != null ? 1 : 0);
      // Skip lanes with nothing to report this run.
      if (remaining == 0 && lane.done == 0 && lane.failed == 0) continue;
      totalDone += lane.done;
      totalFailed += lane.failed;
      total += lane.done + lane.failed + remaining;
      lines.add(_laneNotificationLine(entry.key, lane));
    }
    if (lines.isEmpty) return;

    final failedSuffix = totalFailed > 0 ? ' · $totalFailed failed' : '';
    // First line is the collapsed summary; the per-connector lines expand below.
    final text = (['Uploading $totalDone of $total$failedSuffix', ...lines]).join('\n');
    _showUploadNotification(text);
  }

  /// One connector's status line for the expanded notification.
  String _laneNotificationLine(String name, _UploadLane lane) {
    final delivered = lane.done;
    final laneTotal = lane.done + lane.failed + (lane.current != null ? 1 : 0) + lane.manual.length + lane.auto.length;
    final local = !(_connectorNamed(name)?.capabilities.leavesDevice ?? true);
    if (lane.isPausedBusy(_now())) {
      final why = local ? 'folder unavailable' : 'server busy';
      return '$name — $why, retry ${fmtHourMin(lane.busyUntil!)} ($delivered/$laneTotal)';
    }
    if (lane.current != null) {
      final prog = lane.current!.connector.chunkProgress(_view(lane.current!.conversation));
      final chunk = prog != null ? ' (chunk ${prog.$1 + 1}/${prog.$2})' : '';
      return '$name — ${local ? 'saving' : 'uploading'} $delivered/$laneTotal$chunk';
    }
    if (lane.isEmpty) {
      return lane.failed > 0
          ? '$name — $delivered/$laneTotal done · ${lane.failed} failed'
          : '$name — $delivered/$laneTotal done';
    }
    return '$name — $delivered/$laneTotal queued';
  }

  /// True when auto work was held back since the last sweep that ran and the hold has
  /// lifted — the application owner's cue to reload and re-run. Asking does not clear it; only a
  /// sweep that actually runs does, so a re-run whose batch reload fails is retried
  /// rather than lost.
  bool get deferredSweepReady => _autoSweepDeferred && !_isProcessing();

  /// A failed transfer or pending server job needs rediscovery even when no UI,
  /// archive or connectivity event arrives. The owner reloads settled metadata
  /// before sweeping, so retries receive current authorization and source paths.
  /// A failed reload does not consume this request.
  bool get retrySweepReady =>
      !_isDisposed() && _automaticRetryAt.values.any((at) => !at.isAfter(_now())) && !_isProcessing();

  void _requestRetrySweep(String name, Duration delay) {
    if (_isDisposed()) return;
    final at = _now().add(delay);
    if (_automaticRetryAt[name] == null || at.isBefore(_automaticRetryAt[name]!)) _automaticRetryAt[name] = at;
  }

  static bool _isAutomatic(AuthorizedUpload grant) =>
      grant.basis == AuthorizationBasis.automaticOptIn || grant.basis == AuthorizationBasis.automaticBackfill;

  /// React to an entitlement change without clearing configuration or manual work.
  /// Active automatic sends observe this at their existing safe cancellation checkpoints.
  void automationChanged({bool discover = true}) {
    _automationRevision++;
    for (final lane in _lanes.values) {
      lane.auto.removeWhere((j) => _isAutomatic(j.grant) && !_policy.isStillAuthorized(j.connector, j.grant));
      final current = lane.current;
      if (current != null && _isAutomatic(current.grant) && automation.requiresWifi(current.connector)) {
        unawaited(_checkActiveWifi(lane, current, _automationRevision));
      }
    }
    if (!_isDisposed()) _notifyUi();
    if (discover) tryAutoUploadAll();
  }

  /// Tightening conditions withdraws an active automatic send at its next safe
  /// checkpoint when Wi-Fi cannot be confirmed. Manual work remains untouched.
  Future<void> _checkActiveWifi(_UploadLane lane, UploadJob job, int revision) async {
    var onWifi = false;
    try {
      onWifi = await _checkOnWifi();
    } catch (_) {
      // A condition we cannot verify must fail closed.
    }
    if (!_isDisposed() &&
        revision == _automationRevision &&
        identical(lane.current, job) &&
        automation.requiresWifi(job.connector) &&
        !onWifi) {
      lane.cancelCurrentKey = job.key;
    }
  }

  bool _coreEligible(Conversation c) =>
      !c.passthrough &&
      c.duration.inSeconds >= _prefs.filterMinDurationSeconds &&
      c.duration > Duration.zero &&
      c.fileSizeBytes > 0;

  /// Preview and confirmed selection use the same filter; a confirm can never enlarge
  /// the preview snapshot. This is archive automation, even though starting it is explicit.
  List<String> backfillCandidates(String connectorName) {
    final connector = _connectorNamed(connectorName);
    if (isChangingCredentials(connectorName)) return [];
    if (connector == null || _isProcessing() || automation.settingsFor(connector) == null) return [];
    return {
      for (final batch in _batchesProvider())
        for (final c in batch.finalizedRecordings)
          if (_coreEligible(c) &&
              _policy.canBackfill(connector, _candidateView(c)) &&
              !connector.hasDelivered(_view(c)) &&
              !connector.isBackingOff(_view(c)) &&
              !connector.hasExhaustedRetries(_view(c)))
            c.uploadKey ?? c.file.path,
    }.toList();
  }

  int startBackfill(String connectorName, List<String> confirmedIds) {
    final connector = _connectorNamed(connectorName);
    if (isChangingCredentials(connectorName)) return 0;
    if (connector == null || !automation.isAvailable(connector) || _isProcessing()) return 0;
    final settings = automation.settingsFor(connector);
    if (settings == null) return 0;
    final eligible = backfillCandidates(connectorName).toSet().intersection(confirmedIds.toSet());
    settings.backfillIds = {...settings.backfillIds, ...eligible}.toList();
    tryAutoUploadAll();
    return eligible.length;
  }

  void stopBackfill(String connectorName) {
    final connector = _connectorNamed(connectorName);
    if (connector == null) return;
    automation.settingsFor(connector)?.backfillIds = [];
    automationChanged();
  }

  /// The unattended sweep: for every connector the user put in automatic (or review)
  /// mode, proposes each finished recording that still needs sending and enqueues the
  /// ones the [SharingPolicy] authorizes without asking. Skips delivered, backing-off
  /// and retry-exhausted recordings first, so nothing is proposed that could not go.
  /// A connector in manual mode is never touched here. Held while recordings are
  /// unsettled; see [deferredSweepReady].
  void tryAutoUploadAll() {
    if (_isDisposed()) return;
    // Never while audio is being processed. A run moves each finished recording
    // into place as soon as its bin is decoded, but stitches drafts only at its end,
    // so a sweep in between can upload a recording the same run is about to fold
    // into the draft before it and delete — and the merged recording then uploads
    // again. Nor while the clock pass re-files outside a run: the sweep would queue
    // names about to change. Held, not dropped: the application owner re-runs it once
    // recordings settle.
    if (_isProcessing()) {
      _autoSweepDeferred = true;
      return;
    }
    _autoSweepDeferred = false;
    _automaticRetryAt.clear();
    final minDuration = _prefs.filterMinDurationSeconds;

    // Held by the same gate as the sweep, so it only ever sees settled names. Its own
    // lock orders it against the lane's uploads. Each connector is shown only the
    // recordings it already has — never the rest of the archive.
    final finished = [for (final batch in _batchesProvider()) ...batch.finalizedRecordings];
    for (final connector in _connectors) {
      if (!connector.capabilities.reconcilesDeliveries) continue;
      final delivered = [
        for (final c in finished.map(_view))
          if (connector.hasDelivered(c)) c
      ];
      if (delivered.isEmpty) continue;
      unawaited(connector.reconcile(delivered).catchError((Object e) {
        Logger.error('reconcile(${connector.name}) failed: $e');
      }));
    }

    // Reconciliation remains Free. Unattended candidate discovery and rule evaluation
    // require Pro, including passthrough and automatic retries of newly selected work.
    if (!automation.entitlements.isPro) {
      pumpAllLanes();
      if (!_isDisposed()) _notifyUi();
      return;
    }

    for (final batch in _batchesProvider().reversed) {
      final sortedConversations = [...batch.finalizedRecordings]..sort((a, b) => a.startTime.compareTo(b.startTime));
      for (final conversation in sortedConversations) {
        if (conversation.passthrough) continue;
        if (conversation.duration.inSeconds < minDuration) continue;
        if (conversation.duration == Duration.zero || conversation.fileSizeBytes == 0) continue;

        final recording = _candidateView(conversation);
        for (final connector in _connectors) {
          if (isChangingCredentials(connector.name)) continue;
          if (!connector.capabilities.supportsAutomaticSending) continue;
          // Eligibility first, as before the connector boundary existed: it is what rules
          // out a recording with no upload key, which a connector's retry key assumes.
          switch (_policy.modeFor(connector)) {
            case ApprovalMode.manual:
              if (!automation.requestedBackfill(connector, recording)) continue;
            case ApprovalMode.automatic:
              if (!_policy.allowsAutomaticRecording(connector, recording) &&
                  !automation.requestedBackfill(connector, recording)) {
                continue;
              }
              if (!automation.eligible(connector, recording) && !automation.requestedBackfill(connector, recording)) {
                continue;
              }
            case ApprovalMode.reviewQueue:
              if (!connector.canSend(recording)) continue;
          }
          if (connector.hasDelivered(recording)) continue;
          // Retry budget exhausted for this recording.
          if (_prefs.getAutoUploadRetries(connector.retryKey(recording)) >= 3) continue;
          // Restore retry discovery from saved server backoff, including after restart.
          // The owner reloads recordings and permissions when the deadline passes.
          if (connector.isBackingOff(recording)) {
            _requestRetrySweep(
                connector.name, connector.backingOffUntil(recording)?.difference(_now()) ?? _busyBackoff);
            continue;
          }

          final grant =
              _policy.authorizeUnattended(connector, _policy.propose(connector, _candidateView(conversation)));
          if (grant == null) continue;
          _enqueueUpload(connector, conversation, grant, force: false, manual: false);
        }
      }
    }
    pumpAllLanes();
    if (!_isDisposed()) _notifyUi();
  }

  Connector? _connectorNamed(String name) {
    for (final c in _connectors) {
      if (c.name == name) return c;
    }
    return null;
  }

  bool isChangingCredentials(String name) => (_lanes[name]?.credentialTransitions ?? 0) > 0;

  /// Includes work not in memory: partial chunks, remote jobs, retry/backoff,
  /// confirmed backfill and eligible automation waiting for a sweep/conditions.
  bool hasPendingWorkFor(String name) {
    final connector = _connectorNamed(name);
    if (connector == null) return false;
    if (activeUploadCountFor(name) > 0 ||
        connector.hasIncompleteDelivery ||
        _policy.hasPendingAuthorization(connector)) {
      return true;
    }
    if (_isProcessing() && automation.isEffective(connector)) return true;
    return _batchesProvider().any((batch) => batch.finalizedRecordings.any((c) =>
        _coreEligible(c) &&
        !connector.hasDelivered(_view(c)) &&
        _policy.allowsAutomaticRecording(connector, _candidateView(c)) &&
        automation.eligible(connector, _candidateView(c))));
  }

  /// The caller has already obtained any required user confirmation. Freeze
  /// synchronously, settle the old lane, invalidate unfinished authorization and
  /// transport state, then install credentials. Other destinations keep running.
  Future<void> replaceCredentialsFor(String name, Future<void> Function() install) {
    if (_isDisposed()) return Future.error(StateError('Integration service is disposed'));
    final connector = _connectorNamed(name);
    if (connector == null) return Future.error(StateError('Unknown integration'));
    final lane = _lane(name);
    final boundary = _now();
    final recordings = [
      for (final batch in _batchesProvider()) ...batch.finalizedRecordings.map(_view),
      if (lane.current != null) lane.current!.grant.recording,
      for (final job in [...lane.manual, ...lane.auto]) job.grant.recording,
    ];
    lane.credentialTransitions++;
    lane.cancelRequested = true;
    _purgeQueuedFor(name);
    _resumeTimers.remove(name)?.cancel();
    _automaticRetryAt.remove(name);
    lane.busyUntil = null;
    _notifyUi();
    final transition = lane.transitionTail.catchError((Object _) {}).then((_) async {
      await lane.drainSettled?.future;
      if (_isDisposed()) throw StateError('Integration service is disposed');
      await _policy.beginCredentialTransition(connector, boundary, recordings: recordings);
      await connector.clearIncompleteDelivery();
      if (_isDisposed()) throw StateError('Integration service is disposed');
      await install();
    }).whenComplete(() {
      lane.credentialTransitions--;
      if (lane.credentialTransitions == 0) lane.cancelRequested = false;
      if (!_isDisposed()) {
        _finalizeIfAllIdle();
        _notifyUi();
      }
    });
    lane.transitionTail = transition;
    return transition;
  }

  /// Cancels uploads for [connectorName]: drops queued jobs and signals the
  /// in-flight upload (if any) to abort at its next safe checkpoint. Called when
  /// the user turns off the connector's Enabled or automatic-sending toggle.
  ///
  /// When [autoOnly] (the Auto-Upload toggle), only *auto* jobs are touched — a
  /// manual upload the user explicitly triggered keeps running and queued manual
  /// jobs are left alone. When false (the Enabled toggle / full disable),
  /// everything for the connector is cancelled.
  ///
  /// A chunked upload (Omi Cloud) stops between chunks/polls, keeping
  /// already-delivered chunks; a single-shot one (HeyPocket) can only be stopped
  /// before its request begins — one already mid-request drains. Cancelled jobs
  /// aren't marked failed; auto ones re-enqueue on a later sweep only if the
  /// connector is re-enabled.
  void cancelUploadsFor(String connectorName, {bool autoOnly = false}) {
    final lane = _lanes[connectorName];
    if (lane == null) return;

    final int dropped;
    if (autoOnly) {
      dropped = lane.auto.length;
      lane.auto.clear();
    } else {
      dropped = _purgeQueuedFor(connectorName); // manual + auto
    }

    // Abort the in-flight upload — but for an auto-only cancel, only if that
    // in-flight job is itself an auto job (never interrupt a manual upload). The
    // job stays in _syncingKeys / shown as "uploading" until it actually reaches
    // its cancel checkpoint and bails (its finally clears the tracking), so the
    // row spinner and the detail sheet agree while it's winding down.
    final current = lane.current;
    final cancelInFlight = current != null && (!autoOnly || !current.manual);
    if (cancelInFlight) lane.cancelRequested = true;
    Logger.debug('IntegrationUploadManager: $connectorName ${autoOnly ? 'auto-upload off' : 'disabled'} — '
        'dropped $dropped queued${cancelInFlight ? ', signalled in-flight upload to stop' : ''}');
    if (!_isDisposed()) _notifyUi();
  }

  /// Number of uploads (in-flight + queued, manual + auto) currently active for
  /// [connectorName]. Drives the cancel UI's choice between cancelling just one
  /// recording and prompting to clear the whole queue.
  int activeUploadCountFor(String connectorName) {
    final lane = _lanes[connectorName];
    if (lane == null) return 0;
    return lane.manual.length + lane.auto.length + (lane.current != null ? 1 : 0);
  }

  /// True when [c]'s upload to [connectorName] is genuinely in-flight or queued
  /// in that lane — i.e. there's actually something for [cancelUpload] to act on.
  /// Gates the row's Cancel affordance so it never appears for the phantom
  /// "uploading" shown during the between-retries window (an auto job that failed
  /// but still has retry budget is rendered as uploading yet has no in-flight job
  /// or queue entry; cancelling it would be a silent no-op).
  bool isCancellableUpload(Conversation c, String connectorName) {
    final lane = _lanes[connectorName];
    if (lane == null) return false;
    final key = '${connectorName}_${c.file.path}';
    return lane.current?.key == key || lane.manual.any((j) => j.key == key) || lane.auto.any((j) => j.key == key);
  }

  /// True once a cancel has been requested for [c]'s *in-flight* upload to
  /// [connectorName] but the worker hasn't reached its checkpoint and bailed
  /// yet (single-job cancel, whole-lane cancel, or a disable toggle). Lets the row
  /// show "Cancelling…" and drop the button so the user gets feedback and can't
  /// spam it during the wind-down. Clears itself once the job exits and the row
  /// re-derives.
  bool isCancellingUpload(Conversation c, String connectorName) {
    final lane = _lanes[connectorName];
    if (lane == null) return false;
    final key = '${connectorName}_${c.file.path}';
    if (lane.current?.key != key) return false;
    return lane.cancelRequested || lane.cancelCurrentKey == key;
  }

  /// Cancels a single upload of [c] to [connectorName], leaving the rest of the
  /// lane's queue draining. A queued job is dropped; the in-flight job is
  /// signalled to bail at its next checkpoint (Omi Cloud stops between
  /// chunks/polls; HeyPocket can't be interrupted once its single request is in
  /// flight). An auto job cancelled here may re-enqueue on a later sweep while the
  /// connector's automatic sending is still on; a manual one stays cancelled.
  void cancelUpload(Conversation c, String connectorName) {
    final lane = _lanes[connectorName];
    if (lane == null) return;
    final key = '${connectorName}_${c.file.path}';
    final before = lane.manual.length + lane.auto.length;
    lane.manual.removeWhere((j) => j.key == key);
    lane.auto.removeWhere((j) => j.key == key);
    final removedQueued = before != lane.manual.length + lane.auto.length;
    // Not in the queue but currently uploading → bail just this job; the worker
    // keeps draining whatever is queued behind it.
    final cancelInFlight = !removedQueued && lane.current?.key == key;
    if (cancelInFlight) lane.cancelCurrentKey = key;

    if (removedQueued || cancelInFlight) {
      Logger.debug('IntegrationUploadManager: cancelled ${cancelInFlight ? 'in-flight' : 'queued'} '
          'upload of ${c.uploadKey} to $connectorName');
      if (!_isDisposed()) _notifyUi();
    }
  }

  /// Cancels everything for [connectorName] — in-flight + queued (manual and
  /// auto) — clearing its queue. Same mechanism as a full connector disable.
  void cancelAllUploadsFor(String connectorName) => cancelUploadsFor(connectorName);

  /// The user asked for [conversation] to go to every connector that can take it
  /// (the row's Upload, a day's "Upload All", "Upload Selected"). That request is the
  /// approval: each connector gets a grant for exactly this recording, whatever its
  /// automatic-sending setting — which is why an explicit upload works on recordings
  /// made before automatic sending was switched on.
  Future<List<UploadFailure>> uploadConversation(Conversation conversation, {bool force = false}) async {
    if (_isDisposed()) throw StateError('Integration service is disposed');
    final uploadKey = conversation.uploadKey;
    if (uploadKey == null) throw Exception('Upload key unavailable');

    // A missing source (e.g. Omi's absent Opus frame sidecar) is filtered by canSend.
    final recording = _view(conversation);
    var enqueued = 0;
    for (final connector in _connectors) {
      if (isChangingCredentials(connector.name)) continue;
      if (!connector.canSend(recording)) continue;
      if (!force && connector.hasDelivered(recording)) continue;
      final grant = _policy.approveUserRequest(_policy.propose(connector, _candidateView(conversation)));
      _enqueueUpload(connector, conversation, grant, force: force, manual: true);
      enqueued++;
    }

    if (enqueued == 0) {
      return [UploadFailure('Integrations', Exception('No integrations enabled for upload'))];
    }
    pumpAllLanes();
    _notifyUi();
    return [];
  }

  /// Passed to [Connector.send] so each delivered chunk repaints the connector rows
  /// with the new "X/Total chunks" count live.
  void _notifyChunkProgress() {
    if (!_isDisposed()) _notifyUi();
  }

  /// Per-connector upload status for [c] across all *configured* connectors, for the
  /// detail sheet and the row badge. Both the aggregate [uploadStatus] and
  /// [actionableIntegrationCount] derive from this so the row icon, badge, and sheet
  /// never disagree.
  List<IntegrationStatus> integrationStatuses(Conversation c) {
    final result = <IntegrationStatus>[];
    final recording = _view(c);
    for (final connector in _connectors) {
      if (!connector.isConfigured) continue;
      final state = _connectorState(connector, c, recording);
      DateTime? failedAt;
      if (state == IntegrationUploadState.failed) {
        final ms = _prefs.getAutoUploadLastFailureAt(connector.retryKey(recording));
        if (ms > 0) failedAt = DateTime.fromMillisecondsSinceEpoch(ms);
      }
      final progress = connector.chunkProgress(recording);
      result.add(IntegrationStatus(
        connector.name,
        state,
        failedAt: failedAt,
        deliveredSegments: progress?.$1,
        totalSegments: progress?.$2,
        local: !connector.capabilities.leavesDevice,
        unavailableReason: connector.unavailableReason,
      ));
    }
    return result;
  }

  IntegrationUploadState _connectorState(Connector connector, Conversation c, IntegrationRecording r) {
    if (connector.hasDelivered(r)) return IntegrationUploadState.delivered;
    final key = '${connector.name}_${c.file.path}';
    if (_syncingKeys.contains(key)) return IntegrationUploadState.uploading;
    final lane = _lanes[connector.name];
    if (lane != null && (lane.manual.any((j) => j.key == key) || lane.auto.any((j) => j.key == key))) {
      return IntegrationUploadState.queued;
    }
    if (!connector.canSend(r)) return IntegrationUploadState.unavailable;

    final retryKey = connector.retryKey(r);
    // Has any attempt failed? `hasExhaustedRetries` covers the auto retry-budget
    // exhaustion; the timestamp also covers a manual failure (which doesn't touch the
    // retry count). Without this a manual failure would stay stuck on "pending".
    final hasFailed = connector.hasExhaustedRetries(r) || _prefs.getAutoUploadLastFailureAt(retryKey) > 0;
    if (!hasFailed) return IntegrationUploadState.pending;

    // Auto-upload retries immediately (no backoff) up to 3 times. While it still
    // has budget for this recording, surface the whole retry window as
    // "Uploading" rather than flickering to failed between the back-to-back
    // attempts. Only once retries are exhausted, or automatic sending won't handle
    // this recording (disabled, before the cutoff, or a manual-only failure), is it a
    // real failure.
    final candidate = _candidateView(c);
    final autoWillRetry =
        (automation.eligible(connector, candidate) || automation.requestedBackfill(connector, candidate)) &&
            _prefs.getAutoUploadRetries(retryKey) < 3;
    return autoWillRetry ? IntegrationUploadState.uploading : IntegrationUploadState.failed;
  }

  /// How many applicable connectors still need attention for [c] — i.e. are
  /// `pending` or `failed` (see [IntegrationStatus.isActionable]). Drives the
  /// row badge count: shown only when >= 2, so the number reflects how many
  /// connectors remain to be addressed rather than the total configured.
  int actionableIntegrationCount(Conversation c) => integrationStatuses(c).where((s) => s.isActionable).length;

  UploadStatus uploadStatus(Conversation c) {
    if (!_connectors.any((connector) => connector.isConfigured)) return UploadStatus.unavailable;

    // Aggregate the worst state that needs attention. Anything 'unavailable'
    // (a connector that can't take this recording) is ignored; if none
    // apply, the recording is unavailable rather than a red "tap to upload".
    final relevant = integrationStatuses(c).where((s) => s.state != IntegrationUploadState.unavailable).toList();
    if (relevant.isEmpty) return UploadStatus.unavailable;
    if (relevant.every((s) => s.state == IntegrationUploadState.delivered)) return UploadStatus.all;
    if (relevant.any((s) => s.state == IntegrationUploadState.failed)) return UploadStatus.failed;
    if (relevant.any((s) =>
        s.state == IntegrationUploadState.delivered ||
        s.state == IntegrationUploadState.uploading ||
        s.state == IntegrationUploadState.queued)) {
      return UploadStatus.partial; // in progress (delivered/uploading/queued) — don't prompt to act
    }
    return UploadStatus.none; // all pending, nothing delivered yet
  }

  bool isUploaded(Conversation c) => uploadStatus(c) == UploadStatus.all;

  /// Every configured connector that can take [c] has it — the condition passthrough
  /// mode waits for before it deletes the local audio.
  bool deliveredEverywhereAvailable(Conversation c) {
    final r = _view(c);
    for (final connector in _connectors) {
      if (connector.canSend(r) && !connector.hasDelivered(r)) {
        Logger.debug('Passthrough blocked by ${connector.name}');
        return false;
      }
    }
    return true;
  }

  /// Uploads [c] to the one connector named [connectorName] (the per-row action in
  /// the detail sheet). An explicit user request, so it is its own approval. Tracks
  /// progress per-connector via [_syncingKeys] so only that sheet row spins. Returns
  /// failures (empty = ok).
  Future<List<UploadFailure>> uploadOne(Conversation c, String connectorName, {bool force = false}) async {
    if (_isDisposed()) throw StateError('Integration service is disposed');
    final connector = _connectorNamed(connectorName);
    if (connector == null) return [UploadFailure(connectorName, Exception('Unknown integration'))];
    if (isChangingCredentials(connectorName)) {
      return [UploadFailure(connectorName, Exception('Account change in progress — try again when it finishes'))];
    }
    final recording = _view(c);
    if (!connector.canSend(recording)) {
      return [UploadFailure(connectorName, Exception('not available for this recording'))];
    }
    if (!force && connector.hasDelivered(recording)) return [];

    final grant = _policy.approveUserRequest(_policy.propose(connector, _candidateView(c)));
    _enqueueUpload(connector, c, grant, force: force, manual: true);
    pumpAllLanes();
    _notifyUi();
    return [];
  }
}
