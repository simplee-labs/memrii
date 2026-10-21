import 'dart:io';

import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_api_client.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/integrations/sharing/upload_authorization.dart';
import 'package:omi/utils/logger.dart';

/// Omi Cloud: uploads a recording's Opus frames — its Opus frame sidecar, written at
/// processing time while this connector is enabled — to the user's Omi account, one
/// 3-minute chunk per request, strictly one after another. Signed in through the Omi login
/// web view; tokens in secure storage.
///
/// All of its upload state — delivered list, chunk marks, chunk totals, job ids, backoff,
/// busy streak and the retry budget — is keyed by the sidecar's path, which is derived
/// from the recording's file name. A re-file therefore has to carry that state along
/// ([onRecordingMoved]); the recording layer moves the sidecar file itself.
class OmiCloudConnector extends Connector {
  OmiCloudConnector(this._prefs);

  final SharedPreferencesUtil _prefs;

  static const connectorName = 'Omi Cloud';

  @override
  String get name => connectorName;

  @override
  ConnectorCapabilities get capabilities => const ConnectorCapabilities(
        leavesDevice: true,
        sendsAudio: true,
        chunked: true,
        needsOpusFrameSidecar: true,
      );

  /// The Enabled toggle alone — not [isConfigured], which also needs a sign-in. A user
  /// who has turned Omi Cloud on but not finished signing in still gets sidecars, so the
  /// recordings made meanwhile can be sent once they do.
  @override
  bool get wantsOpusFrameSidecar => _prefs.omiEnabled;

  @override
  bool get isConfigured => _prefs.omiEnabled && OmiApiClient.isSignedIn;

  @override
  String get credentialFingerprint => OmiApiClient.credentialGeneration.toString();

  @override
  bool get hasIncompleteDelivery => _prefs.hasIncompleteOmiUploads;

  @override
  Iterable<String> get incompleteDeliveryKeys => _prefs.incompleteOmiUploadKeys;

  @override
  Future<void> clearIncompleteDelivery() => _prefs.clearIncompleteOmiUploads();

  @override
  bool get isAutomaticSendingEnabled => _prefs.omiAutoUpload;

  @override
  bool isEligibleForAutomatic(IntegrationRecording r) {
    if (!canSend(r)) return false;
    final enabledAt = _prefs.omiAutoUploadAt;
    // No recorded consent time means no automatic send. Older recordings remain
    // available for explicit manual upload when their Opus sidecar exists.
    if (enabledAt <= 0) return false;
    return !r.startTime.isBefore(DateTime.fromMillisecondsSinceEpoch(enabledAt));
  }

  // Omi can only upload the processing-time sidecar, which is written solely while Omi
  // Cloud is enabled. Recordings processed before then have none and cannot be sent at
  // all — on request or otherwise.
  @override
  bool canSend(IntegrationRecording r) => isConfigured && r.hasOpusFrameSidecar;

  @override
  String get unavailableReason => 'Recorded before Omi sync was enabled';

  @override
  bool hasDelivered(IntegrationRecording r) => _prefs.isOmiSynced(r.opusFrameSidecarPath);

  @override
  bool hasExhaustedRetries(IntegrationRecording r) => _prefs.getAutoUploadRetries(r.opusFrameSidecarPath) >= 3;

  @override
  String retryKey(IntegrationRecording r) => r.opusFrameSidecarPath;

  /// Exponential backoff after the server reports it's busy/overloaded (a 503, or a
  /// 502/504 gateway timeout): 5m, 10m, 20m, 40m, capped at 60m, indexed by the
  /// consecutive-busy streak. A backend that's down for a while is polled progressively
  /// less often instead of every 5 min — and never given up on (the 3-strike give-up
  /// budget is reserved for genuine content/4xx failures). The next automatic sweep after
  /// the window elapses picks the recording back up.
  static const Duration _busyBackoffBase = Duration(minutes: 5);
  static const Duration _busyBackoffCap = Duration(minutes: 60);

  static Duration _busyBackoffFor(int streak) {
    // streak is 1 on the first busy: base, then doubling each consecutive busy.
    final shift = (streak - 1).clamp(0, 30);
    final ms = _busyBackoffBase.inMilliseconds << shift;
    final capMs = _busyBackoffCap.inMilliseconds;
    return Duration(milliseconds: (ms < 0 || ms > capMs) ? capMs : ms);
  }

  @override
  (int, int)? chunkProgress(IntegrationRecording r) {
    final binPath = r.opusFrameSidecarPath;
    final total = _prefs.getOmiSegmentTotal(binPath);
    if (total <= 1) return null; // single chunk: no per-chunk progress worth showing
    return (_prefs.omiSyncedSegmentCount(binPath), total);
  }

  @override
  DateTime? backingOffUntil(IntegrationRecording r) {
    final until = _prefs.getOmiBackoffUntil(r.opusFrameSidecarPath);
    if (until <= DateTime.now().millisecondsSinceEpoch) return null;
    return DateTime.fromMillisecondsSinceEpoch(until);
  }

  @override
  Future<void> send(AuthorizedUpload upload, {void Function()? onProgress, bool Function()? isCancelled}) async {
    final generation = OmiApiClient.credentialGeneration;
    bool cancelled() => (isCancelled?.call() ?? false) || generation != OmiApiClient.credentialGeneration;
    final binPath = upload.recording.opusFrameSidecarPath;
    final binFile = File(binPath);
    if (!binFile.existsSync()) {
      throw Exception('no Omi upload file for this recording — it was processed before Omi sync was enabled');
    }

    final segments = await OmiApiClient.buildSegments(binFile);
    if (segments.isEmpty) throw Exception('Omi upload found no audio to send');
    // Record the chunk count so the UI can show "delivered/total" — kept across a
    // partial failure so a failed-midway upload reports how far it got.
    await _prefs.setOmiSegmentTotal(binPath, segments.length);
    onProgress?.call();

    // Upload one segment per request, serialized: the server runs a single Parakeet
    // transcription per job, and firing several in parallel 503s the STT backend.
    // Each delivered segment is recorded so a retry resumes from the first
    // undelivered chunk. A chunk whose job is still running (or whose poll budget
    // elapsed) stops the run as `pending` — NOT a failure: its job id is kept so
    // the next attempt reattaches and polls the same job rather than re-uploading
    // and adding a duplicate to the server's queue. Only a server `failed` verdict
    // re-uploads.
    OmiSyncResult? lastResult;
    try {
      for (var i = 0; i < segments.length; i++) {
        // Bail before starting (or re-attaching) the next chunk if the user
        // disabled the integration / its auto-upload mid-run. Already-delivered
        // chunks stay synced; the rest resume on a later run if re-enabled.
        if (cancelled()) return;
        final segmentKey = '$binPath#$i';
        if (_prefs.isOmiSegmentSynced(segmentKey)) continue;

        final existingJobId = _prefs.getOmiSegmentJobId(segmentKey);
        final outcome =
            await OmiApiClient.syncSegment(segments[i], existingJobId: existingJobId, isCancelled: cancelled);

        switch (outcome.status) {
          case OmiJobStatus.completed:
            await _prefs.markOmiSegmentSynced(segmentKey);
            await _prefs.clearOmiSegmentJobId(segmentKey);
            await _prefs.clearOmiBusyStreak(binPath); // backend healthy again — reset backoff
            onProgress?.call();
            lastResult = outcome.result;
          case OmiJobStatus.pending:
            // Server still has the job in flight. Persist its id and stop without
            // failing — the recording stays "pending" and a later run reattaches.
            // Clear the up-front attempt marker so it reads pending, not failed.
            if (outcome.jobId != null) await _prefs.setOmiSegmentJobId(segmentKey, outcome.jobId!);
            await _prefs.clearAutoUploadRetry(binPath);
            return;
          case OmiJobStatus.busy:
            // Server overloaded or its gateway timed out (a 503, or a 502/504).
            // The chunk's job (if any) is dead, so drop its id and re-upload later
            // — but not now: set an exponential backoff (escalating with each
            // consecutive busy) so auto-upload leaves a struggling backend alone
            // for progressively longer. Not a failure; don't spend the give-up
            // budget, and clear the up-front failure marker.
            await _prefs.clearOmiSegmentJobId(segmentKey);
            await _prefs.clearAutoUploadRetry(binPath);
            await _prefs.incrementOmiBusyStreak(binPath);
            final streak = _prefs.getOmiBusyStreak(binPath);
            final backoff = _busyBackoffFor(streak);
            await _prefs.setOmiBackoffUntil(binPath, DateTime.now().add(backoff).millisecondsSinceEpoch);
            Logger.debug('Omi Cloud: server busy on segment ${i + 1}/${segments.length}; '
                'backing off ${backoff.inMinutes}m (streak $streak)');
            return;
          case OmiJobStatus.failed:
          case OmiJobStatus.gone:
            // Real server verdict — drop the stale job id so the retry re-uploads.
            await _prefs.clearOmiSegmentJobId(segmentKey);
            // Remote errors can echo request credentials; never put them in diagnostics.
            throw Exception('Omi upload failed on segment ${i + 1}/${segments.length}');
        }
      }
    } catch (e) {
      if (e is OmiSyncException && e.isAuthError && generation == OmiApiClient.credentialGeneration) {
        _prefs.omiEnabled = false;
      }
      rethrow;
    }

    // Every segment delivered — promote to a fully-synced recording and prune the
    // now-redundant per-segment markers (and any leftover job ids).
    await _prefs.markOmiSynced(binPath);
    await _prefs.clearOmiSegments(binPath);
    await _prefs.clearAutoUploadRetry(binPath);
    if (lastResult != null && !cancelled()) {
      await OmiApiClient.traceSyncResult(lastResult, isCancelled: cancelled);
    }
  }

  /// Carries every piece of upload state kept under the old sidecar path over to the new
  /// one. Moved also when the recording had no sidecar to move: a delivered mark describes
  /// the recording's audio, and dropping it would send that audio again. Merges rather
  /// than overwrites (see `SharedPreferencesUtil.moveOmiUploadState`).
  @override
  Future<void> onRecordingMoved(RecordingMove move) async {
    try {
      final from = IntegrationRecording.opusFrameSidecarPathOf(move.fromAudioPath);
      final to = IntegrationRecording.opusFrameSidecarPathOf(move.toAudioPath);
      await _prefs.moveOmiUploadState(from, to);
    } catch (e) {
      Logger.error('Omi Cloud: moving upload state for ${move.fromAudioPath} failed: $e');
    }
  }

  @override
  Future<void> forget(List<IntegrationRecording> deleted) async =>
      _prefs.removeOmiSynced(deleted.map((r) => r.opusFrameSidecarPath));

  @override
  Future<void> forgetDeliveryHistory() async => _prefs.clearOmiSyncedFiles();

  @override
  String? credentialFailureMessage(Object error) => error is OmiSyncException && error.isAuthError
      ? 'Omi sync: credentials invalid — update them in Integrations'
      : null;

  /// Refreshes the Omi token once per process so the first send does not pay for it.
  @override
  Future<void> onServicesStarted() async {
    if (!_prefs.omiEnabled) return;
    final generation = OmiApiClient.credentialGeneration;
    try {
      await OmiApiClient.refreshTokenIfNeeded();
    } catch (e) {
      // Use the API client's shared rejection classifier. Outages and stale
      // refreshes do not prove that the currently saved account is invalid.
      if (e is OmiSyncException && e.isAuthError && generation == OmiApiClient.credentialGeneration) {
        _prefs.omiEnabled = false;
      }
      Logger.error('ServiceManager: Omi token refresh on startup failed (${e.runtimeType})');
    }
  }
}
