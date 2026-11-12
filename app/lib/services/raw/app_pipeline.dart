// The new recordings pipeline in the app (RECORDINGS_PIPELINE_REDESIGN.md step 6): one
// coordinator on the archive edit queue, the processing pass after each sync, the user
// actions, and the update from earlier builds. Everything runs on the main isolate:
// the coordinator must share the queue with the app's other archive edits, Silero runs
// on the native runner's own thread, and decoding yields as it goes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/services/device_clock_anchor.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/raw/actions.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
import 'package:omi/services/raw/legacy_update.dart';
import 'package:omi/services/raw/pipeline.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/raw/render.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/set_aside_bins.dart';
import 'package:omi/services/vad/vad_types.dart';
import 'package:omi/services/vad_batch_runner_channel.dart';
import 'package:omi/services/wals/sdcard_wal_sync.dart';
import 'package:omi/utils/atomic_file.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/wal_file_manager.dart';

/// What the recordings page shows of the last pass, kept across launches.
class PipelineStatus {
  /// Files the last pass planned from: any other file on the phone is new since.
  final Set<String> seen;

  /// Files with audio still to process after it.
  final Set<String> waiting;

  /// Conversations open where it stopped: (start, length, Priority Recording).
  final List<({int? startMs, int durationMs, bool inPriority})> open;

  const PipelineStatus(this.seen, this.waiting, this.open);

  static const empty = PipelineStatus({}, {}, []);

  /// Whether [rel]'s audio is still to process.
  bool isPending(String rel) => !seen.contains(rel) || waiting.contains(rel);

  factory PipelineStatus.of(PassReport r) => PipelineStatus(
        {for (final k in r.seen) k.rel},
        {for (final k in r.waiting) k.rel},
        [for (final o in r.open) (startMs: o.startMs, durationMs: o.durationMs, inPriority: o.inPriority)],
      );

  Map<String, Object?> toJson() => {
        'seen': seen.toList()..sort(),
        'waiting': waiting.toList()..sort(),
        'open': [
          for (final o in open) {'startMs': o.startMs, 'durationMs': o.durationMs, 'priority': o.inPriority}
        ],
      };

  static PipelineStatus fromJson(Map<String, Object?> j) => PipelineStatus(
        {...((j['seen'] as List?) ?? const []).cast<String>()},
        {...((j['waiting'] as List?) ?? const []).cast<String>()},
        [
          for (final o in ((j['open'] as List?) ?? const []).cast<Map>())
            (
              startMs: o['startMs'] as int?,
              durationMs: (o['durationMs'] as int?) ?? 0,
              inPriority: o['priority'] == true,
            )
        ],
      );
}

/// SetAsideBins as the pipeline's book: the page's list, failure strikes, and the retry
/// a newer build owes.
class PrefsSetAsideBook implements SetAsideBook {
  @override
  Set<RawFileKey> listed() => SetAsideBins.relBins().map(RawFileKey.fromRel).whereType<RawFileKey>().toSet();

  @override
  Future<void> list(RawFileKey key) async {
    if (SetAsideBins.entryFor(key.rel) == null) await SetAsideBins.skip(key.rel);
  }

  @override
  void unlist(RawFileKey key) => SetAsideBins.release(key.rel);

  @override
  Future<bool> recordFailure(RawFileKey key) async {
    await SetAsideBins.recordFailure(key.rel);
    return SetAsideBins.entryFor(key.rel) != null;
  }

  @override
  void recordSuccess(Iterable<RawFileKey> keys) => SetAsideBins.recordSuccess(keys.map((k) => k.rel));

  @override
  Set<RawFileKey> retryDue() => {
        for (final e in SetAsideBins.list())
          if (e.retryPending) RawFileKey.fromRel(e.relBin)
      }.whereType<RawFileKey>().toSet();
}

class AppPipeline {
  AppPipeline._();

  static final AppPipeline instance = AppPipeline._();

  /// A separate instance, for tests: [instance] starts once per process.
  @visibleForTesting
  AppPipeline.forTest();

  Future<void>? _started;
  late String _docs;
  late OwnershipCoordinator coordinator;
  late ArchiveActions actions;
  late RawBinGate gate;
  bool _updated = false;

  PipelineStatus status = PipelineStatus.empty;

  bool _running = false;
  bool _cancelRequested = false;
  VadBatchRunnerChannel? _vad;
  bool _recovering = false;

  bool get isRunning => _running;

  /// Startup, before any download or processing: the update from an earlier build, once,
  /// then journal recovery. Every entry point awaits it.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    _docs = (await getApplicationDocumentsDirectory()).path;
    coordinator = OwnershipCoordinator(_docs, queue: RecordingsManager.editArchive);
    actions = ArchiveActions(coordinator);
    gate = RawBinGate(coordinator);
    RawChunkStore.enabled = true;
    SDCardWalSyncImpl.onSourceMismatch = setAside;
    try {
      await LegacyUpdate(coordinator, capMinutesNow: SharedPreferencesUtil().priorityRecordMaxMinutes).runOnce();
      _updated = true;
    } catch (e, st) {
      // Nothing is processed on a half-seeded ledger: the next launch tries again.
      Logger.handle(e, st, message: 'AppPipeline: the update from the earlier build failed; processing waits');
    }
    try {
      await coordinator.recover();
    } catch (e) {
      Logger.error('AppPipeline: journal recovery failed: $e');
    }
    // Parts a crash left are sealed now, before any listing: their saved progress is in
    // wals.json, which the first listing replaces (and a file the Omi has reclaimed since
    // is not listed at all).
    try {
      final ends = <RawFileKey, int>{};
      for (final w in await WalFileManager.loadWals()) {
        final key = RawFileKey(w.timerStart, w.sessionId);
        if (w.walOffset > (ends[key] ?? 0)) ends[key] = w.walOffset;
      }
      final changed = await coordinator.store.recover(persistedEnd: (key) => ends[key]);
      if (changed.isNotEmpty) Logger.debug('AppPipeline: sealed the parts a crash left in ${changed.length} file(s)');
      SDCardWalSyncImpl.partsRecovered = true;
    } catch (e) {
      Logger.error('AppPipeline: sealing the parts a crash left failed: $e');
    }
    try {
      final f = File('$_docs/pipeline_sessions.json');
      if (await f.exists()) _ended.addAll(((jsonDecode(await f.readAsString()) as Map)['ended'] as List).cast<int>());
    } catch (e) {
      Logger.error('AppPipeline: pipeline_sessions.json unreadable ($e)');
    }
    try {
      final f = File('$_docs/pipeline_status.json');
      if (await f.exists()) status = PipelineStatus.fromJson((jsonDecode(await f.readAsString()) as Map).cast());
    } catch (e) {
      Logger.error('AppPipeline: pipeline_status.json unreadable ($e)');
    }
  }

  /// Stops the pass running now at its next check; nothing it already committed changes.
  void cancel() => _cancelRequested = true;

  /// One processing pass (§5). With [force], first a boundary at the end of what is here
  /// in every session: what is open closes, holes before it are waived (Force Sync).
  /// Null when a pass is already running or the update has not been done.
  Future<PassReport?> runPass(
      {bool force = false, void Function()? onLiveness, void Function(double done)? onProgress}) async {
    await start();
    if (!_updated) {
      Logger.error('AppPipeline: not processing — the update from the earlier build has not completed');
      return null;
    }
    if (_running) return null;
    _running = true;
    _cancelRequested = false;
    try {
      if (force) await forceAll();
      final report = await _pass(onLiveness: onLiveness, onProgress: onProgress);
      status = PipelineStatus.of(report);
      try {
        await AtomicFile.writeString(File('$_docs/pipeline_status.json'), jsonEncode(status.toJson()));
      } catch (e) {
        Logger.error('AppPipeline: could not save the status: $e');
      }
      return report;
    } finally {
      _running = false;
      if (!_recovering) await _releaseVad();
    }
  }

  /// A pass with the app's inputs; [planOnly]: the plan as things stand, nothing changed.
  Future<PassReport> _pass(
      {void Function()? onLiveness, void Function(double done)? onProgress, bool planOnly = false}) async {
    final holes = await _holes();
    final (quiet, quietWhy) = quietOf(holes.listedOn, _clockAnchors());
    Logger.debug('AppPipeline: ${quiet == null ? 'no quiet mark' : 'quiet mark'} ($quietWhy)');
    final live = ProcessingSettings.fromPrefs();
    final cards = CardBuilder(
      store: coordinator.store,
      decoderId: OpusFrameDecoder.id,
      newDecoder: OpusFrameDecoder.new,
      model: SileroBatchModel(await _vadRunner()),
      onLiveness: onLiveness,
      isCancelled: () => _cancelRequested,
    );
    final report = await RawPipeline(
      coordinator: coordinator,
      actions: actions,
      gate: gate,
      cards: cards,
      book: PrefsSetAsideBook(),
      newJob: () => PublishJob(
        coordinator: coordinator,
        newDecoder: OpusFrameDecoder.new,
        encoder: AacAudioEncoder(),
        freeBytes: RecordingsManager.freeBytes,
        isCancelled: () => _cancelRequested,
        onLiveness: onLiveness,
      ),
    ).run(
      PassInputs(
        policies: _policies(live),
        capMinutesNow: SharedPreferencesUtil().priorityRecordMaxMinutes,
        settings: PublishSettings(
          deviceId: live.deviceId,
          m4a: live.audioSaveFormat == 'm4a',
          opusSidecar: live.writeOpusFrameSidecar,
        ),
        nowMs: DateTime.now().millisecondsSinceEpoch,
        missing: holes.missing,
        waived: holes.waived,
        anchors: _anchors(),
        knownEnded: {..._ended},
        listing: listingOf(holes.listedOn, DeviceConnection.liveSession),
        quiet: quiet,
      ),
      isCancelled: () => _cancelRequested,
      planOnly: planOnly,
      onProgress: onProgress,
    );
    // A session found ended stays ended, whatever happens to the anchors since.
    if (!report.ended.every(_ended.contains)) {
      _ended.addAll(report.ended);
      try {
        await AtomicFile.writeString(
            File('$_docs/pipeline_sessions.json'), jsonEncode({'ended': _ended.toList()..sort()}));
      } catch (e) {
        Logger.error('AppPipeline: could not save the ended sessions: $e');
      }
    }
    return report;
  }

  /// Sessions found ended (kept in `pipeline_sessions.json`).
  final Set<int> _ended = {};

  /// Releases the native Silero session, as today's processing did after each run.
  Future<void> _releaseVad() async {
    final vad = _vad;
    _vad = null;
    if (vad == null) return;
    try {
      await vad.dispose();
    } catch (e) {
      Logger.error('AppPipeline: releasing the Silero runner failed: $e');
    }
  }

  /// Force / finish early: a boundary at the end of what is here in each session.
  Future<void> forceAll() async {
    await start();
    final store = coordinator.store;
    final last = <int?, RawFileKey>{};
    for (final k in await store.listKeys()) {
      final had = last[k.sessionId];
      if (had == null || compareKeys(k, had) > 0) last[k.sessionId] = k;
    }
    final boundaries = [
      for (final k in last.values) PlanBoundary(BoundaryKind.force, k, (await store.load(k)).length),
    ];
    if (boundaries.isNotEmpty) await actions.force(boundaries);
  }

  // ---- user actions ----

  Future<void> setAside(RawFileKey key) async {
    await start();
    await actions.setAside(key);
    await PrefsSetAsideBook().list(key);
  }

  /// Delete, for a set-aside or raw file.
  Future<void> deleteRawFile(RawFileKey key) async {
    await start();
    await actions.deleteRawFile(key, nowMs: DateTime.now().millisecondsSinceEpoch);
    SetAsideBins.release(key.rel);
    await gate.release(candidates: [key]);
  }

  /// Try again: off the set-aside list, its card built again by the next pass.
  Future<void> tryAgain(RawFileKey key) async {
    await start();
    await actions.tryAgain(key);
    SetAsideBins.release(key.rel);
  }

  Future<int> deleteDiscards(Iterable<String> ids) async {
    await start();
    final n = await actions.deleteDiscards(ids);
    await gate.release();
    return n;
  }

  Future<RecoverResult> recoverDiscards(List<String> ids) async {
    await start();
    _recovering = true;
    try {
      return await _recoverDiscards(ids);
    } finally {
      _recovering = false;
      if (!_running) await _releaseVad();
    }
  }

  Future<RecoverResult> _recoverDiscards(List<String> ids) async {
    final live = ProcessingSettings.fromPrefs();
    final keys = <RawFileKey>{};
    for (final date in await _dates()) {
      for (final r in await coordinator.readDiscardLines(date)) {
        if (!ids.contains(r['id'])) continue;
        keys.addAll(
            ((r['binRanges'] as Map?) ?? const {}).keys.map((k) => RawFileKey.fromRel(k as String)).whereType());
        final id = r['id'] as String;
        final own = RawFileKey.fromRel(id.split('@').first);
        if (own != null) keys.add(own);
      }
    }
    final builder = CardBuilder(
      store: coordinator.store,
      decoderId: OpusFrameDecoder.id,
      newDecoder: OpusFrameDecoder.new,
      model: SileroBatchModel(await _vadRunner()),
    );
    final cards = <RawFileKey, FileCard>{};
    for (final k in keys) {
      if ((await coordinator.store.load(k)).chunks.isEmpty) continue;
      cards[k] = await builder.current(k);
    }
    final result = await actions.recoverDiscards(
      ids,
      cards: cards,
      newDecoder: OpusFrameDecoder.new,
      encoder: AacAudioEncoder(),
      settings: PublishSettings(
        deviceId: live.deviceId,
        m4a: live.audioSaveFormat == 'm4a',
        opusSidecar: live.writeOpusFrameSidecar,
      ),
      freeBytes: RecordingsManager.freeBytes,
    );
    await gate.release();
    return result;
  }

  /// Delete Day (§7). Returns the deleted recordings' paths relative to the documents
  /// directory (audio, or the meta of a passthrough recording).
  Future<List<String>> deleteDay(String date) async {
    await start();
    // What is unsaved now, not as the last pass saw it: no pass runs meanwhile, and the
    // plan is made afresh from everything on the phone.
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _running = true;
    // A Stop tapped earlier, with no pass since to take it, is not this one's: it would
    // stop the plan below before it starts.
    _cancelRequested = false;
    try {
      final holes = await _holes();
      final p = date.split('-').map(int.parse).toList();
      final dayEnd = DateTime(p[0], p[1], p[2] + 1).millisecondsSinceEpoch;
      final PassReport report;
      try {
        report = await _pass(planOnly: true);
      } finally {
        if (!_recovering) await _releaseVad();
      }
      final known = {...await coordinator.store.listKeys(), ...holes.listed};
      // Files whose end is not known yet: still on the Omi, or still arriving.
      final near = [
        for (final k in known)
          if (startsNearMidnight(k, dayEnd)) k
      ];
      final entries = await coordinator.ledger.entriesFor(near);
      final unfinished = <RawFileKey>{
        for (final k in near)
          if (entries[k]?.receipt == null && !_finished(await coordinator.store.load(k))) k
      };
      final keep = keptByDeleteDay(report, dayEnd, known, unfinished);
      if (keep.isNotEmpty) {
        Logger.debug('AppPipeline: Delete Day $date keeps ${[for (final k in keep) k.stem]}'
            '${unfinished.isEmpty ? '' : '; not arrived yet near midnight: ${[for (final k in unfinished) k.stem]}'}');
      }
      final deleted =
          await actions.deleteDay(date, nowMs: DateTime.now().millisecondsSinceEpoch, listed: holes.listed, keep: keep);
      await gate.release();
      return deleted;
    } finally {
      _running = false;
    }
  }

  static bool _finished(LogicalRawFile f) => f.chunks.isNotEmpty && f.lifecycle.isTerminal;

  /// What Delete Day keeps of the day ending at [dayEnd], from [report], its plan made
  /// just before: what [crossingMidnight] keeps, and each [unfinished] file (its end not
  /// known yet: still on the Omi, or still arriving) that starts close enough to midnight
  /// to run past it. Better kept, and its minutes before midnight back on the deleted day,
  /// than its minutes after midnight lost with it. Throws, so that nothing is deleted,
  /// when the plan was not made (a Stop during it).
  @visibleForTesting
  static Set<RawFileKey> keptByDeleteDay(
      PassReport report, int dayEnd, Set<RawFileKey> known, Set<RawFileKey> unfinished) {
    if (report.stop != PassStop.done) {
      throw StateError('Delete Day stopped (${report.stop.name}) before it could see what crosses midnight; '
          'nothing was deleted');
    }
    final mayCross = {
      for (final k in unfinished)
        if (startsNearMidnight(k, dayEnd)) k
    };
    final plan = report.plan;
    return {...mayCross, if (plan != null) ...crossingMidnight(plan, dayEnd, known, unresolved: mayCross)};
  }

  /// The Omi starts a new file every ten minutes, so a file that starts this close to
  /// [dayEnd] or closer may run past it.
  static const Duration longestFile = Duration(minutes: 15);

  @visibleForTesting
  static bool startsNearMidnight(RawFileKey k, int dayEnd) =>
      k.timerStart >= _minValidEpochSeconds &&
      k.timerStart * 1000 < dayEnd &&
      k.timerStart * 1000 >= dayEnd - longestFile.inMilliseconds;

  /// The files of what is not saved yet and crosses the midnight at [dayEnd], or may: a
  /// closed item that runs past it, and a conversation still open that started before it
  /// and either runs past it already or whose session has a file from midnight on or one
  /// of [unresolved] (its end is unresolved). Delete Day keeps them, so that audio after
  /// midnight is never lost with the day.
  @visibleForTesting
  static Set<RawFileKey> crossingMidnight(Plan plan, int dayEnd, Set<RawFileKey> known,
      {Set<RawFileKey> unresolved = const {}}) {
    final keep = <RawFileKey>{};
    for (final item in plan.items) {
      final (int start, int end) = switch (item) {
        final PlannedRecording r => (r.startMs, r.startMs + r.durationMs),
        final PlannedDiscard d => (d.startMs, d.endMs),
        PlannedOrphans() => (0, 0),
      };
      if (start < dayEnd && end > dayEnd) keep.addAll(item.spans.map((s) => s.key));
    }
    for (final o in plan.open) {
      final first = o.firstKey;
      final start = o.startMs;
      if (first == null || start == null || start >= dayEnd) continue;
      final session = [
        for (final k in known)
          if (k.sessionId == first.sessionId && compareKeys(k, first) >= 0) k
      ];
      final open = session.any(
          (k) => (k.timerStart >= _minValidEpochSeconds && k.timerStart * 1000 >= dayEnd) || unresolved.contains(k));
      if (start + o.durationMs > dayEnd || open) keep.addAll(session);
    }
    return keep;
  }

  static const int _minValidEpochSeconds = 946684800;

  /// Save original file: [key]'s chunks, in order, into [out].
  Future<void> exportRaw(RawFileKey key, File out) async {
    await start();
    await actions.exportRaw(key, out);
  }

  Future<void> deletePhoneConversations() async {
    await start();
    await actions.deletePhoneConversations();
    await gate.release();
  }

  Future<void> deletePhoneSegments() async {
    await start();
    await actions.deletePhoneSegments(nowMs: DateTime.now().millisecondsSinceEpoch);
  }

  /// Reprocess all, first half (Adjustment Mode): released files come back from Adjustment
  /// Mode's copies (never a deleted one, never over another file on the phone). Throws,
  /// with no recording or setting changed, when nothing would be rebuilt; otherwise
  /// returns the files restored, for [reprocessAll].
  Future<Set<RawFileKey>> prepareReprocess() async {
    await start();
    final restored = await _restoreAdjustmentCopies();
    final store = coordinator.store;
    final keys = await store.listKeys();
    final entries = await coordinator.ledger.entriesFor(keys);
    // A set-aside file stays set aside through the rebuild, which skips it.
    final setAside = (await coordinator.ledger.loadStream()).setAside.toSet();
    var sources = 0;
    for (final k in keys) {
      final e = entries[k];
      if (e?.tombstone != null || (e?.receipt != null && !restored.contains(k))) continue;
      if (setAside.contains(k)) continue;
      if ((await store.load(k)).chunks.isNotEmpty) sources++;
    }
    if (sources == 0) throw StateError('No source segments are available. Existing recordings have been kept.');
    return restored;
  }

  /// Reprocess all, second half: the reset (§7), [restored]'s receipts forgotten in it;
  /// a pass then rebuilds everything on the phone.
  Future<void> reprocessAll(Set<RawFileKey> restored) async {
    await start();
    await actions.reprocessAll(restored: restored);
  }

  /// Copies of released files from `adjustment_mode_segments/` back into `raw_segments/`,
  /// adopted as one imported chunk with what their receipts kept (§13's form). A copy
  /// whose length is not its receipt's is not the same file and stays out. A copy an
  /// interrupted Reprocess all already put back (its length its receipt's) counts as
  /// restored again; a copy is written under another name and renamed into place, so a
  /// half-written one is never taken for it.
  Future<Set<RawFileKey>> _restoreAdjustmentCopies() async {
    final root = Directory('$_docs/adjustment_mode_segments');
    final restored = <RawFileKey>{};
    if (!await root.exists()) return restored;
    final store = coordinator.store;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.bin')) continue;
      final key = RawFileKey.fromRel(e.path.replaceAll('\\', '/').split('/adjustment_mode_segments/').last);
      if (key == null) continue;
      final entry = (await coordinator.ledger.entriesFor([key]))[key];
      if (entry?.tombstone != null) continue;
      final receipt = entry?.receipt;
      final length = await e.length();
      if (receipt != null && receipt.length != length) {
        Logger.warning('AppPipeline: ${key.rel}: the Adjustment Mode copy holds $length bytes, its receipt '
            '${receipt.length}; not restored');
        continue;
      }
      final onPhone = await store.load(key);
      if (onPhone.chunks.isNotEmpty) {
        // Put back by a Reprocess all that stopped before its reset: still the same file.
        if (receipt != null && onPhone.length == receipt.length) {
          await store.adoptLegacy(key,
              lifecycle: receipt.lifecycle,
              advertisedLength: receipt.advertisedLength,
              firstSealedAtMs: receipt.firstSealedAtMs);
          restored.add(key);
        }
        continue;
      }
      final target = File('${store.folderOf(key).path}/${key.chunkName(0)}');
      if (await target.exists()) continue;
      await target.parent.create(recursive: true);
      final staged = File('${target.path}.restore');
      await e.copy(staged.path);
      await staged.rename(target.path);
      await store.adoptLegacy(
        key,
        lifecycle: receipt?.lifecycle ?? SourceLifecycle.complete,
        advertisedLength: receipt?.advertisedLength ?? length,
        firstSealedAtMs: receipt?.firstSealedAtMs ?? (await e.lastModified()).millisecondsSinceEpoch,
      );
      if (receipt != null) restored.add(key);
    }
    if (restored.isNotEmpty) Logger.info('AppPipeline: Reprocess all restored ${restored.length} file(s)');
    return restored;
  }

  /// The Priority Recording cap setting, when it changes.
  Future<void> recordCap(int minutes) async {
    await start();
    final caps = (await coordinator.ledger.loadStream()).caps;
    if (caps.isNotEmpty && caps.last.minutes == minutes) return;
    await actions.recordCap(atMs: DateTime.now().millisecondsSinceEpoch, minutes: minutes);
  }

  // ---- inputs ----

  Future<List<String>> _dates() async {
    final root = Directory('$_docs/recordings');
    if (!await root.exists()) return const [];
    return [
      await for (final e in root.list(followLinks: false))
        if (e is Directory) e.uri.pathSegments.lastWhere((s) => s.isNotEmpty)
    ];
  }

  Future<
      ({
        List<RawFileKey> missing,
        Set<RawFileKey> waived,
        Set<RawFileKey> listed,
        ({int atMs, int link, int linkSinceMs})? listedOn
      })> _holes() async {
    try {
      final sync = ServiceManager.instance().wal.getSyncs();
      if (sync is SDCardWalSyncImpl) return await sync.rawFileState();
    } catch (e) {
      Logger.error('AppPipeline: the Omi\'s file list is unavailable ($e); planning without it');
    }
    return (
      missing: const <RawFileKey>[],
      waived: const <RawFileKey>{},
      listed: const <RawFileKey>{},
      listedOn: null,
    );
  }

  /// The Omi's file list as a pass may find ended sessions by it ([PassInputs.listing]):
  /// when the sync took it complete ([listedOn]), with the session the Omi said it was in
  /// when it said so on the same link ([live]). A session read on another link may not be
  /// the one the list was taken in.
  static ({int atMs, int? liveSession})? listingOf(
      ({int atMs, int link, int linkSinceMs})? listedOn, ({int link, int sessionId})? live) {
    if (listedOn == null) return null;
    final same = live != null && live.link == listedOn.link;
    return (atMs: listedOn.atMs, liveSession: same ? live.sessionId : null);
  }

  /// How long before the phone saw a link come up the Omi had listed everything it
  /// recorded. On a connect the Omi closes the file it is writing (so the list taken next
  /// names it) unless the file holds no audio or is under two minutes old
  /// (BLE_CONNECT_MIN_ROTATE_AGE_MS, sd_card.c; since oo-3.0.4); and the phone sees the
  /// link ready within seconds of the Omi's connect (native allows 15 s to discover the
  /// services after it): a minute more covers that.
  static const int connectQuietMarginMs = 3 * 60 * 1000;

  /// The quiet mark a pass plans with ([QuietMark]): [connectQuietMarginMs] before the
  /// link the sync took its complete list on ([listedOn]) came up, with each session's
  /// uptime then, from its newest clock anchor ([anchors], the newest last). A session's
  /// anchor also shows it ran firmware that reports its session (oo-3.1.0 on), which closes
  /// its file on a connect. Null, with why, without such a list.
  @visibleForTesting
  static (QuietMark?, String) quietOf(
      ({int atMs, int link, int linkSinceMs})? listedOn, List<DeviceClockAnchor> anchors) {
    if (listedOn == null) return (null, 'no complete list of the Omi\'s files taken since the app started');
    if (listedOn.linkSinceMs <= 0) return (null, 'the link the list was taken on has no start time');
    final atMs = listedOn.linkSinceMs - connectQuietMarginMs;
    final newest = <int, DeviceClockAnchor>{for (final a in anchors) a.sessionId: a};
    final uptimeAt = {
      for (final a in newest.values) a.sessionId: (a.deviceUptimeMs + atMs - a.wallClockMs) & 0xFFFFFFFF,
    };
    return (
      QuietMark(atMs, uptimeAt),
      '${_clock(atMs)}: the list from ${_clock(listedOn.atMs)} was taken on link ${listedOn.link}, '
          'up at ${_clock(listedOn.linkSinceMs)}; uptime then known for session(s) ${uptimeAt.keys.toList()}',
    );
  }

  static String _clock(int ms) => DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();

  /// The clock anchors (the newest last), or none when they cannot be read.
  static List<DeviceClockAnchor> _clockAnchors() {
    try {
      return DeviceClockAnchorSet.decode(SharedPreferencesUtil().deviceClockAnchors).anchors;
    } catch (_) {
      return const [];
    }
  }

  /// The sessions the phone saw live, from the clock anchors (the newest last).
  static List<({int sessionId, int atMs})> _anchors() => [
        for (final a in _clockAnchors()) (sessionId: a.sessionId, atMs: a.wallClockMs),
      ];

  static PlanPolicy _policyOf(ModeSettings m) => PlanPolicy(
        vadEnabled: m.vadEnabled,
        speechThreshold: m.speechThreshold,
        silenceSplitMs: m.silenceDurationToSplitMs,
        minSpeechMs: m.minSpeechMs,
        maxChunkMs: m.maxChunkMs,
        manual: m.manual,
      );

  /// The policy each file was recorded under: the mode-switch history, each switch with
  /// the mode it left, and the mode now.
  static PolicyHistory _policies(ProcessingSettings live) => PolicyHistory(_policyOf(live.mode), [
        for (final r in ModeSwitchRecord.decode(SharedPreferencesUtil().processingModeSwitchHistory))
          (atUtcSeconds: r.atUtcSeconds, before: _policyOf(r.settings)),
      ]);

  /// The native Silero runner, with the model copied out of the assets once.
  Future<VadBatchRunnerChannel> _vadRunner() async {
    final had = _vad;
    if (had != null && had.available) return had;
    final runner = VadBatchRunnerChannel();
    try {
      final dir = await getApplicationSupportDirectory();
      final cached = File('${dir.path}/silero_vad_v6.onnx');
      if (!await cached.exists()) {
        final data = await rootBundle.load('assets/models/silero_vad.onnx');
        await cached.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      await runner.init(cached.path);
    } catch (e) {
      // Cards fail and are retried: never cards made as if there were no speech model.
      Logger.error('AppPipeline: the Silero runner could not start: $e');
    }
    return _vad = runner;
  }
}
