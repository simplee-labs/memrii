import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:disk_space_2/disk_space_2.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/connector.dart';
import 'package:omi/integrations/connector_registry.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/models/recordings/recording_filename.dart';
import 'package:omi/services/audio/recording_cropper.dart';
import 'package:uuid/uuid.dart';
import 'package:omi/services/device_clock_anchor.dart';
import 'package:omi/services/discard_store.dart';
import 'package:omi/services/recording_sidecars.dart';
import 'package:omi/services/raw/app_pipeline.dart';
import 'package:omi/services/raw/pipeline.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/set_aside_bins.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/atomic_file.dart';
import 'package:omi/utils/logger.dart';

// Re-export the recording domain models so existing importers of this file keep
// working without touching their import lists. The model definitions now live in
// models/recordings/recordings_models.dart.
export 'package:omi/models/recordings/recordings_models.dart';

/// Try again was asked while a processing pass was going. Nothing was attempted.
class ProcessingBusy implements Exception {
  const ProcessingBusy();

  @override
  String toString() => 'Another processing task is already in progress.';
}

/// What [RecordingsManager.retrySetAsideBin] did with a set-aside bin.
enum SetAsideRetry {
  /// Its unsaved audio was decoded and saved as recordings of its own; it is no longer
  /// set aside.
  recovered,

  /// Nothing in it was left to save; it is no longer set aside.
  nothingLeft,

  /// It is not known where its unsaved audio begins, and a saved recording already holds
  /// part of it, so decoding it again would duplicate that recording. It stays set aside,
  /// to share or delete.
  cannotRetry,

  /// It is no longer on the phone; its entry is gone too.
  gone,
}

class RecordingsManager {
  static final RecordingsManager _instance = RecordingsManager._internal();
  factory RecordingsManager() => _instance;
  RecordingsManager._internal();

  static bool _isProcessingAny = false;
  static bool get isProcessingAny => _isProcessingAny;

  /// Archive edits and clock passes in flight — a counter because the passes
  /// nest and can overlap with crop saves or a date chosen by the user.
  /// See [recordingsUnsettled].
  static int _refileDepth = 0;

  /// Crop saves and date corrections share a queue: neither may rename or
  /// clean up paths another edit is still using.
  static Future<void> _archiveEditQueue = Future.value();

  static Future<T> _editArchive<T>(Future<T> Function() edit) async {
    _refileDepth++;
    final previous = _archiveEditQueue;
    final done = Completer<void>();
    _archiveEditQueue = done.future;
    try {
      await previous;
      await _waitForRetention();
      return await edit();
    } finally {
      done.complete();
      _refileDepth--;
      if (!recordingsUnsettled) notifyRecordingsChanged();
    }
  }

  /// [_editArchive] for a change made outside this class to a recording's files —
  /// passthrough's flag and audio delete. Every `.meta` writer goes through the queue:
  /// [AtomicFile] stages each target at one temp path, so two writers of the same meta at
  /// once can tear it.
  static Future<T> editArchive<T>(Future<T> Function() edit) => _editArchive(edit);

  // Retention owns file deletion until this completes. Processing and date
  // correction announce themselves before waiting, so a cleanup still listing
  // files can yield to them without deleting from a stale snapshot.
  static Completer<void>? _retentionDone;
  static Future<void> _waitForRetention() => _retentionDone?.future ?? Future<void>.value();

  /// True while recordings on disk may still be renamed or deleted: a processing pass
  /// ([runPipelinePass]), a clock-anchor pass re-filing outside one (the controller's
  /// `_finishPipelineRun`), or automatic retention. The auto-upload sweep and queued auto
  /// uploads wait on it, and the late-merge message is not shown under it. Deliberately
  /// not folded into [isProcessingAny]: that one drives the recordings page into its
  /// processing state and turns a second pass away, and a re-file pass is neither.
  static bool get recordingsUnsettled => _isProcessingAny || _refileDepth > 0 || _retentionDone != null;

  /// Recordings an upload is reading right now, by path, counted — HeyPocket and Omi can
  /// upload the same recording at once. Maintained by IntegrationUploadManager around
  /// each upload; [promoteSessionToDate] will not rename one of these (see there).
  static final Map<String, int> _uploadsInFlight = {};

  static String _inFlightKey(File audio) => audio.path.replaceAll('\\', '/');

  static void noteUploadStarted(File audio) {
    final k = _inFlightKey(audio);
    _uploadsInFlight[k] = (_uploadsInFlight[k] ?? 0) + 1;
  }

  static void noteUploadFinished(File audio) {
    final k = _inFlightKey(audio);
    final n = (_uploadsInFlight[k] ?? 0) - 1;
    if (n > 0) {
      _uploadsInFlight[k] = n;
      return;
    }
    _uploadsInFlight.remove(k);
    // The last upload reading it is done: apply a re-file that had to wait for it.
    if (_readPendingRefiles().containsKey(k)) unawaited(_applyDeferredRefile(k));
  }

  static bool isUploading(File audio) => _uploadsInFlight.containsKey(_inFlightKey(audio));

  /// A process restart, for tests: nothing is uploading any more, and nothing is applied.
  @visibleForTesting
  static void forgetUploadsInFlightForTest() => _uploadsInFlight.clear();

  // Re-files [promoteSessionToDate] had to put off because an upload was reading the
  // recording, by path: the offset its move would have used, and whether it was a clock
  // correction. Persisted (pref `pendingRefiles`) so a date set by hand is not lost if
  // the app is killed before the upload ends. Applied when the last upload reading the
  // recording finishes ([noteUploadFinished]) and at the start of every clock pass
  // ([applyClockAnchors]), which is what catches one left over from a killed app.

  static Map<String, dynamic> _readPendingRefiles() {
    final raw = SharedPreferencesUtil().pendingRefiles;
    if (raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static void _writePendingRefiles(Map<String, dynamic> pending) =>
      SharedPreferencesUtil().pendingRefiles = pending.isEmpty ? '' : jsonEncode(pending);

  static void _deferRefile(File audio, int offsetMs, bool markClockCorrected) {
    final pending = _readPendingRefiles();
    // The latest wins: a date set again before the upload ends replaces the first.
    pending[_inFlightKey(audio)] = {'offsetMs': offsetMs, 'clockCorrected': markClockCorrected};
    _writePendingRefiles(pending);
  }

  static Future<void> _applyDeferredRefiles() async {
    for (final key in _readPendingRefiles().keys.toList()) {
      if (_uploadsInFlight.containsKey(key)) continue; // still waiting for its upload
      await _applyDeferredRefile(key);
    }
  }

  static Future<void> _applyDeferredRefile(String key) async {
    final pending = _readPendingRefiles();
    final entry = pending.remove(key);
    if (entry is! Map) return;
    // Taken before the move: if another upload has started on it meanwhile,
    // promoteSessionToDate simply defers it again.
    _writePendingRefiles(pending);
    try {
      final file = File(key);
      if (!await file.exists()) return; // deleted, or folded into another recording, since
      final conv = Conversation.fromFile(file);
      final uptime = conv.startUptimeMs;
      final offsetMs = entry['offsetMs'];
      if (uptime == null || uptime <= 0 || offsetMs is! int) return;
      await promoteSessionToDate(conv, DateTime.fromMillisecondsSinceEpoch(uptime + offsetMs),
          markClockCorrected: entry['clockCorrected'] == true, include: (c) => _inFlightKey(c.file) == key);
    } catch (e) {
      Logger.error('RecordingsManager: deferred re-file of ${key.split('/').last} failed: $e');
    }
  }

  /// Keeps [SharedPreferencesUtil.lateMergeNotices] — left by earlier versions, which
  /// joined finished recordings onto drafts — naming the recording the list will show. A notice gives the merged recording by its start, and a re-file changes that
  /// start — in the same run (the clock pass runs after the stitch) or a later one — so
  /// without this the message names a time no recording has. The absorbed half is left
  /// alone: that recording is gone, and its old time is the one the user last saw.
  static void _remapLateMergeNotices(Map<int, int> renamedStarts) {
    final prefs = SharedPreferencesUtil();
    var changed = false;
    final next = <String>[];
    for (final n in prefs.lateMergeNotices) {
      final parts = n.split(':');
      final merged = parts.length == 2 ? int.tryParse(parts[1]) : null;
      final moved = merged == null ? null : renamedStarts[merged];
      if (moved == null) {
        next.add(n);
      } else {
        next.add('${parts[0]}:$moved');
        changed = true;
      }
    }
    if (changed) prefs.lateMergeNotices = next;
  }

  /// The Opus frame sidecar for the recording [audio]: `recording_fs320_<ts>.bin` beside
  /// it, written at processing time while a connector wants one (Omi Cloud uploads it).
  /// One definition — [RecordingSidecars.opusFramesPathFor] — shared by the processor that
  /// writes it, [promoteSessionToDate] that moves it and the connector that reads it.
  static String opusFrameSidecarPathFor(File audio) => RecordingSidecars.opusFramesPathFor(audio.path);

  /// Moves [from]'s Opus frame sidecar to follow the recording now at [to], then tells
  /// the connectors, so one that keys its own state by the recording's path (Omi Cloud's
  /// whole upload state is keyed by the sidecar's) can follow. Left behind, the sidecar is
  /// orphaned — the renamed recording can no longer be sent — and that state says it was
  /// never sent, so automatic sending queues it, fails on the missing file and gives up
  /// after three tries. Never throws: the audio has already moved, and the rest of
  /// [promoteSessionToDate]'s pass must not be abandoned over this.
  static Future<void> _moveOpusFrameSidecar(File from, File to) async {
    final fromBin = opusFrameSidecarPathFor(from);
    final toBin = opusFrameSidecarPathFor(to);
    if (p.equals(fromBin, toBin)) return;
    try {
      final bin = File(fromBin);
      if (await bin.exists()) {
        if (await File(toBin).exists()) {
          // promoteSessionToDate refuses this slot before renaming anything, so only a
          // file that appeared since gets here. Never overwrite it, and leave the
          // connectors' state with the file it describes: moved without it, the renamed
          // recording would be tied to a file that is not its audio.
          Logger.error('RecordingsManager: not moving ${fromBin.split('/').last} onto '
              '${toBin.split('/').last} — that name is already on disk. Left where it is.');
          return;
        }
        await bin.rename(toBin);
      }
    } catch (e) {
      Logger.error('RecordingsManager: moving the Opus frame sidecar for ${from.path} failed: $e');
      return;
    }
    // Told also when there was no sidecar to move: a delivered mark describes the
    // recording's audio, and dropping it would send that audio again.
    await ConnectorRegistry.recordingMoved(RecordingMove(from.path, to.path));
  }

  /// [applyClockAnchors] for the processing paths, which it must never take down.
  static Future<void> _applyClockAnchorsLogged() async {
    try {
      await applyClockAnchors();
    } catch (e) {
      Logger.error('RecordingsManager: clock-anchor pass failed ($e) — timestamps left as the Omi filed them.');
    }
  }

  /// Global progress of the current processing task (0.0 to 1.0).
  static final ValueNotifier<double> processingProgress = ValueNotifier(0.0);

  /// Minutes of audio remaining to process. Updated by RecordingsController;
  /// -1 means unknown (calculating). Read by notification paths in both
  /// foreground and background to show consistent progress text.
  static double minutesRemaining = -1.0;

  /// Bumped on each isolate liveness heartbeat — emitted while the decode/save
  /// loops are actively advancing, so it ticks even within a single long
  /// segment or a multi-hour stitched-recording save where the per-segment
  /// [processingProgress] tick can't. The pipeline-stall watchdog anchors on
  /// this so a healthy-but-slow run isn't force-killed as a wedge.
  static final ValueNotifier<int> processingLiveness = ValueNotifier(0);

  /// True when a WAV file is being transcoded to M4A.
  static final ValueNotifier<bool> isTranscoding = ValueNotifier(false);

  /// True when the "Conversations ready" success notification is being displayed.
  /// Used to prevent the background idle-notification heartbeat from clobbering
  /// the success message before its 10s display window elapses.
  static final ValueNotifier<bool> isSuccessNotificationActive = ValueNotifier(false);

  static bool _cancelRequested = false;

  /// Stop: the pass running now stops at its next check (between frames while a file is
  /// indexed or a recording rendered); nothing it has already saved changes, and the next
  /// pass carries on from there.
  static void cancelProcessing() {
    _cancelRequested = true;
    AppPipeline.instance.cancel();
  }

  /// The recordings page's recovery for a pass that shows no progress: the same request
  /// as [cancelProcessing]. A pass runs on the main isolate, so there is nothing to kill.
  static void forceResetProcessing() => cancelProcessing();

  /// Application notification for archive changes and processing/refile settlement.
  /// Integration automation and UI pages both observe it; no widget is required.
  static final ValueNotifier<int> recordingsChangeNotifier = ValueNotifier(0);
  static void notifyRecordingsChanged() => recordingsChangeNotifier.value++;

  /// Call on app startup to clean up incomplete extraction from a previous crash.
  /// If the persisted extraction-in-progress flag is set, any fully-written m4a/wav
  /// files in the temp directory are rescued to their live recordings/<date>/ folders
  /// first, then the temp directory is removed and the flag is cleared.
  /// Raw segments are intentionally left intact so processing can be retried.
  static Future<void> cleanUpIncompleteExtraction() async {
    final prefs = SharedPreferencesUtil();
    if (!prefs.extractionInProgress) return;

    Logger.debug(
      'RecordingsManager: Detected incomplete extraction from previous run — rescuing completed files.',
    );
    try {
      final directory = await getApplicationDocumentsDirectory();
      final tempDir = Directory('${directory.path}/processing_temp');
      if (await tempDir.exists()) {
        // Rescue any fully-written recordings before deleting the temp dir.
        // This covers the race where the crash happened between _saveRecording()
        // writing the m4a and moveTempFilesToLive() renaming it.
        // Move .meta sidecars first so they are in place when the audio file lands.
        final allEntities = await tempDir.list(recursive: true).where((e) => e is File).cast<File>().toList();
        allEntities.sort((a, b) {
          final aIsMeta = a.path.endsWith('.meta') ? 0 : 1;
          final bIsMeta = b.path.endsWith('.meta') ? 0 : 1;
          return aIsMeta.compareTo(bIsMeta);
        });
        for (final file in allEntities) {
          final fileName = file.path.split('/').last;
          if (!fileName.endsWith('.m4a') && !fileName.endsWith('.wav') && !fileName.endsWith('.meta')) continue;
          final parts = fileName.split('_');
          var millis = parts.length >= 2 ? int.tryParse(parts.last.split('.').first) : null;
          if (millis == null || millis <= 0) continue;
          final dateStr = _dateStringFromMillis(millis);
          final liveDir = Directory('${directory.path}/recordings/$dateStr');
          await liveDir.create(recursive: true);
          final dest = '${liveDir.path}/$fileName';
          try {
            await file.rename(dest);
            Logger.debug(
              'RecordingsManager: Rescued $fileName → recordings/$dateStr/',
            );
          } catch (e) {
            Logger.error('RecordingsManager: Failed to rescue $fileName: $e');
          }
        }
        await tempDir.delete(recursive: true);
        Logger.debug(
          'RecordingsManager: Removed leftover processing_temp directory.',
        );
      }
    } catch (e) {
      Logger.error('RecordingsManager: Failed to clean up processing_temp: $e');
    } finally {
      prefs.extractionInProgress = false;
    }
  }

  /// [folder]'s entries, or none once it is gone. Delete Day and the release of raw files
  /// remove the folders they empty, so a folder listed a moment before may be gone when it
  /// is read: that is one folder fewer, never a list that fails to load.
  static Future<List<FileSystemEntity>> _entriesOf(Directory folder) async {
    try {
      return await folder.list().toList();
    } on FileSystemException {
      return const [];
    }
  }

  Future<List<Batch>> getBatches() async {
    final directory = await getApplicationDocumentsDirectory();
    final rawSegmentsDir = Directory('${directory.path}/raw_segments');
    final recordingsDir = Directory('${directory.path}/recordings');

    Map<String, List<File>> rawSegmentsByDate = {};
    Map<String, List<Conversation>> processedByDate = {};

    // Process raw segments (now they are in DeviceSession folders)
    if (await rawSegmentsDir.exists()) {
      final deviceSessionEntities = await rawSegmentsDir.list().toList();
      final deviceSessionFolders = deviceSessionEntities.whereType<Directory>().toList();

      // Sort session folders by timestamp ID (e.g. "1713892490", "unknown_101", "session_AABBCCDD")
      deviceSessionFolders.sort((a, b) {
        final aName = a.path.split('/').last;
        final bName = b.path.split('/').last;
        final aIdStr = aName.replaceFirst('unknown_', '').replaceFirst('session_', '');
        final bIdStr = bName.replaceFirst('unknown_', '').replaceFirst('session_', '');

        // Folder ids are decimal (session_<sessionId>, unknown_<n>, or a raw timestamp).
        final aId = int.tryParse(aIdStr);
        final bId = int.tryParse(bIdStr);

        return (aId ?? 0).compareTo(bId ?? 0);
      });

      for (var folder in deviceSessionFolders) {
        final deviceSessionIdStr = folder.path.split('/').last;

        // Skip hidden folders or system folders if any
        if (deviceSessionIdStr.startsWith('.')) continue;

        // Process segments
        final folderEntities = await _entriesOf(folder);
        // A logical file is listed once, by its first chunk, and only while its audio is
        // still to process (the pipeline's last pass says which).
        final status = AppPipeline.instance.status;
        final files = folderEntities.whereType<File>().where((f) {
          final name = f.uri.pathSegments.last;
          if (!name.endsWith('.bin') || name.contains('@')) return false;
          return status.isPending('$deviceSessionIdStr/$name');
        }).toList();

        await Future.wait(
          files.map((file) async {
            String dateStr;
            try {
              final name = file.path.split('/').last;
              final tsStr = name.split('_').first;
              final ts = int.tryParse(tsStr);
              // The bin filename timestamp is epoch SECONDS (the WAL timerStart).
              // Convert to ms and group via the canonical local-date helper, so
              // raw bins land in the SAME date batch as their recordings and
              // discard records. (Previously read as ms — `fromMillisecondsSinceEpoch(ts)`
              // — so every UTC-stamped bin fell into a 1970 bucket, splitting it
              // from same-day recordings/discards.) Uptime ticks (pre-time-sync,
              // below kMinValidEpoch) and unparseable names fall back to mtime.
              if (ts != null && ts > 946684800) {
                dateStr = _dateStringFromMillis(ts * 1000);
              } else {
                dateStr = _dateStringFromMillis((await file.lastModified()).millisecondsSinceEpoch);
              }
            } catch (_) {
              try {
                dateStr = _dateStringFromMillis((await file.lastModified()).millisecondsSinceEpoch);
              } on FileSystemException {
                return; // released since its folder was listed: nothing left to show
              }
            }
            rawSegmentsByDate.putIfAbsent(dateStr, () => []).add(file);
          }),
        );
      }
    }

    // Process already processed recordings
    if (await recordingsDir.exists()) {
      final dateFolderEntities = await recordingsDir.list().toList();
      final dateFolders = dateFolderEntities.whereType<Directory>();
      for (var folder in dateFolders) {
        final dateString = p.basename(folder.path);
        final folderEntities = await _entriesOf(folder);
        final files = folderEntities
            .whereType<File>()
            .where(
              (f) => (f.path.endsWith('.m4a') || f.path.endsWith('.wav')) && !f.path.endsWith('.tmp.m4a'),
            )
            .toList();

        final conversations = await Future.wait(
          files.map((f) => Conversation.fromFileAsync(f)),
        );

        // Also pick up passthrough conversations: .meta files with no matching audio file.
        final audioBasenames = files.map((f) {
          final name = f.path.split('/').last;
          return name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
        }).toSet();
        final metaFiles = folderEntities.whereType<File>().where((f) => f.path.endsWith('.meta')).toList();
        final passthroughConvs = <Conversation>[];
        for (final meta in metaFiles) {
          final metaName = meta.path.split('/').last;
          final baseName = metaName.contains('.') ? metaName.substring(0, metaName.lastIndexOf('.')) : metaName;
          if (audioBasenames.contains(baseName)) continue;
          final c = await Conversation.fromMetaOnly(meta);
          if (c != null) passthroughConvs.add(c);
        }

        processedByDate[dateString] = [...conversations, ...passthroughConvs];
      }
    }

    // Discover dates with discard records — a day where ALL audio was rejected
    // produces no recording or raw bin, but still has a discards.jsonl we want
    // to render.
    final discardsByDate = <String, List<DiscardRecord>>{};
    if (await recordingsDir.exists()) {
      await for (final entity in recordingsDir.list()) {
        if (entity is! Directory) continue;
        final dateStr = p.basename(entity.path);
        final loaded = await getDiscardsForDate(dateStr);
        if (loaded.isNotEmpty) discardsByDate[dateStr] = loaded;
      }
    }

    // Merge keys
    final allDates = {
      ...rawSegmentsByDate.keys,
      ...processedByDate.keys,
      ...discardsByDate.keys,
    }.toList();
    List<Batch> batches = [];

    for (var dateStr in allDates) {
      final parts = dateStr.split('-');
      final date = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );

      final raw = rawSegmentsByDate[dateStr] ?? [];
      // Sort raw segments chronologically by their filename. Since filenames are
      // zero-padded hex strings (timestamp_sessionId.bin), string order is correct.
      raw.sort((a, b) {
        final nameA = a.path.split('/').last;
        final nameB = b.path.split('/').last;
        return nameA.compareTo(nameB);
      });

      final allConversations = processedByDate[dateStr] ?? <Conversation>[];
      final finalized = allConversations.where((c) => !c.file.path.contains('_draft.')).toList();
      final drafts = allConversations.where((c) => c.file.path.contains('_draft.')).toList();

      batches.add(
        Batch(
          dateString: dateStr,
          date: date,
          rawSegments: raw,
          draftRecordings: drafts,
          finalizedRecordings: finalized,
          markerTimestamps: const [],
          discards: discardsByDate[dateStr] ?? const [],
        ),
      );
    }

    batches.sort((a, b) => b.date.compareTo(a.date));
    return batches;
  }

  /// Free space on the app's storage, or null when the platform can't say.
  static Future<int?> freeBytes() => freeDiskBytes();

  /// Free space on the app's storage, or null when the platform can't say.
  @visibleForTesting
  static Future<int?> Function() freeDiskBytes = () async {
    try {
      final mb = await DiskSpace.getFreeDiskSpace;
      return mb == null ? null : (mb * 1024 * 1024).toInt();
    } catch (_) {
      return null;
    }
  };

  /// The bins runs left waiting for phone storage, by `raw_segments/`-relative path, with
  /// their raw size.
  static Map<String, int> _storageWaitingBins() {
    final raw = SharedPreferencesUtil().processingWaitingBins;
    if (raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, v is int ? v : 0));
    } catch (_) {
      return {};
    }
  }

  static void _saveStorageWaitingBins(Map<String, int> bins) =>
      SharedPreferencesUtil().processingWaitingBins = bins.isEmpty ? '' : jsonEncode(bins);

  /// Publishes the storage pause — [SharedPreferencesUtil.processingPausedForStorage] and
  /// [SharedPreferencesUtil.processingPausedMinutes], which the recordings page and both
  /// notifications read — from the bins still waiting: on disk, not deleted, not set
  /// aside. The rest are dropped.
  ///
  /// Derived, not set and cleared by whichever run happens to look: audio deleted or set
  /// aside while it waited takes the banner with it at the next refresh, whatever path gets
  /// there, and a run over a few bins neither clears the backlog's pause nor rewrites its
  /// size. Refreshed at the start of every run, by its space check, by a run that ran out
  /// of space, by every prune, and when the recordings pipeline settles.
  ///
  /// Never throws: it runs at the start of runs and inside every prune, and a banner left
  /// as it was is no reason to stop either.
  static Future<void> refreshStoragePause() async {
    try {
      await _refreshStoragePause();
    } catch (e) {
      Logger.error('RecordingsManager: storage-pause refresh failed: $e');
    }
  }

  static Future<void> _refreshStoragePause() async {
    final gone = SetAsideBins.relBins();
    final rawDir = '${(await getApplicationDocumentsDirectory()).path}/raw_segments';
    // No await from here on, so a run noting its space check cannot interleave and be lost.
    final bins = _storageWaitingBins();
    final before = bins.length;
    bins.removeWhere((rel, _) => gone.contains(rel) || !File('$rawDir/$rel').existsSync());
    if (bins.length != before) _saveStorageWaitingBins(bins);
    final prefs = SharedPreferencesUtil();
    final paused = bins.isNotEmpty;
    final minutes = paused ? max(1, (bins.values.fold<int>(0, (a, b) => a + b) / 4050 / 60).ceil()) : 0;
    if (prefs.processingPausedForStorage == paused && prefs.processingPausedMinutes == minutes) return;
    prefs.processingPausedForStorage = paused;
    prefs.processingPausedMinutes = minutes;
    notifyRecordingsChanged();
  }

  /// Test seam for the mid-transfer bin lookup ([WalSync.incompleteBinRelPaths]).
  /// Production resolves it through [ServiceManager], which unit tests never
  /// initialize — without a stub every run would take the fail-closed branch and
  /// the bin-deletion path would go unexercised. Throwing from the stub simulates
  /// an unreadable wals.json.
  @visibleForTesting
  static Future<Set<String>> Function()? incompleteBinResolverForTest;

  @visibleForTesting
  static bool Function()? reprocessSyncInFlightForTest;

  static void _checkReprocessSyncIdle() {
    final syncing = reprocessSyncInFlightForTest?.call() ?? ServiceManager.instance().wal.getSyncs().isSyncInFlight;
    if (syncing) throw StateError('Wait for the current sync to finish before reprocessing.');
  }

  /// Test seam for the held-back bin lookup ([SDCardWalSync.heldBackBinRelPaths]).
  @visibleForTesting
  static Future<Set<String>> Function()? heldBackBinResolverForTest;

  static int _extractTimestamp(String path) {
    return RecordingFilename.timestamp(path) ?? 0;
  }

  static String fmtDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  /// Atomically writes JSON to [target]: write to `<target>.tmp` then rename,
  /// so a concurrent reader never observes a truncated/partial file (NEW3/C5).
  /// Static + public so the marker player's crop-save path (which runs on the
  /// main isolate, not through this manager instance) shares the same
  /// crash-safety as the isolate EDL writers instead of a raw writeAsString.
  static Future<void> writeJsonAtomic(File target, Object payload) =>
      AtomicFile.writeString(target, jsonEncode(payload));

  Future<void> _writeJsonAtomic(File target, Object payload) => writeJsonAtomic(target, payload);

  /// Scans all `recordings/<date>/` folders for `marker_*.edl` files and
  /// returns a list of [MarkerConversation] sorted by markerTime descending.
  /// Pending conversations (no backing m4a yet) are included with [isPending] = true.
  Future<List<MarkerConversation>> getMarkerConversations() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return [];

    final entities = await recordingsDir.list().toList();
    final dateFolders = entities.whereType<Directory>().toList();

    // Build a one-shot filename → File index across all date folders so that
    // missing-segment recovery is O(1) per marker instead of O(folders) (B14).
    final filenameIndex = await _indexRecordingFiles(dateFolders);
    // Step 1: Rapidly scan all date folders for EDL files
    final List<MarkerConversation> allConversations = [];
    for (final dateFolder in dateFolders) {
      final edlFiles = (await _entriesOf(dateFolder))
          .where((e) => e is File && e.uri.pathSegments.last.startsWith('marker_') && e.path.endsWith('.edl'))
          .cast<File>()
          .toList();

      for (final edlFile in edlFiles) {
        try {
          final json = jsonDecode(await edlFile.readAsString()) as Map<String, dynamic>;
          // Keep a removed priority marker on disk so processing cannot resurrect it,
          // without turning it into an ordinary bookmark in the list or integrations.
          if (json['priorityOverride'] == false) continue;
          final markerMs = json['markerTimestampMs'] as int;
          final segmentFilename = json['segmentFilename'] as String?;

          final segmentFile = _resolveMarkerSegment(filenameIndex, segmentFilename);

          // Clamp cropEnd to the segment's actual encoded duration. Pre-0.12.0
          // EDLs stored wall-clock chunk duration which can exceed the playable
          // file length when frames were silently dropped during decode. The
          // in-memory MC always gets the clamped value; if the on-disk EDL
          // was over the encoded duration AND not user-saved (no risk of
          // overwriting user crop intent), persist the clamp back to disk
          // so the next load doesn't re-clamp (B9).
          int cropEndMs = json['cropEndMs'] as int? ?? 0;
          if (segmentFile != null) {
            try {
              final base = segmentFile.path.substring(0, segmentFile.path.lastIndexOf('.'));
              final metaBytes = await File('$base.meta').readAsBytes();
              if (metaBytes.length >= 8) {
                final encodedMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
                if (encodedMs > 0 && (cropEndMs == 0 || cropEndMs > encodedMs)) {
                  final originalOnDisk = cropEndMs;
                  cropEndMs = encodedMs;
                  final userSaved = json['userSaved'] as bool? ?? false;
                  if (!userSaved && originalOnDisk > encodedMs) {
                    json['cropEndMs'] = encodedMs;
                    try {
                      await _writeJsonAtomic(edlFile, json);
                      Logger.debug(
                          'RecordingsManager: Migrated EDL ${edlFile.path.split('/').last} cropEndMs $originalOnDisk→$encodedMs');
                    } catch (e) {
                      Logger.error('RecordingsManager: cropEnd migration write failed: $e');
                    }
                  }
                }
              }
            } catch (_) {}
          }

          allConversations.add(MarkerConversation(
            markerTime: DateTime.fromMillisecondsSinceEpoch(markerMs),
            segment: segmentFile,
            markerOffsetMs: json['markerOffsetMs'] as int? ?? 0,
            cropStartMs: json['cropStartMs'] as int? ?? 0,
            cropEndMs: cropEndMs,
            edlFile: edlFile,
            userSaved: json['userSaved'] as bool? ?? false,
            isHighPriority: json['isHighPriority'] as bool? ?? false,
          ));
        } catch (e) {
          Logger.error('RecordingsManager: Failed to parse EDL ${edlFile.path}: $e');
        }
      }
    }

    // Step 2: Group EDLs by exact markerMs and pick one canonical per ms.
    // Two physical button taps cannot share a UTC ms (firmware ms resolution,
    // taps take much longer than 1 ms), so any group of >1 here is a bug or
    // legacy data — pick the preferred (userSaved > non-pending > earliest
    // basename) and warn on the rest so testing surfaces them in logs.
    final Map<int, List<MarkerConversation>> byMs = {};
    for (final mc in allConversations) {
      byMs.putIfAbsent(mc.markerTime.millisecondsSinceEpoch, () => []).add(mc);
    }
    final List<MarkerConversation> deduped = [];
    for (final group in byMs.values) {
      if (group.length == 1) {
        deduped.add(group.first);
        continue;
      }
      group.sort((a, b) {
        final saveCmp = (b.userSaved ? 1 : 0) - (a.userSaved ? 1 : 0);
        if (saveCmp != 0) return saveCmp;
        final pendCmp = (a.isPending ? 1 : 0) - (b.isPending ? 1 : 0);
        if (pendCmp != 0) return pendCmp;
        return a.edlFile.path.split('/').last.compareTo(b.edlFile.path.split('/').last);
      });
      deduped.add(group[0]);
      Logger.error(
          'RecordingsManager: ${group.length} EDLs at markerMs=${group[0].markerTime.millisecondsSinceEpoch} — keeping ${group[0].edlFile.path.split('/').last}, dropping ${group.skip(1).map((m) => m.edlFile.path.split('/').last).join(", ")}');
    }

    deduped.sort((a, b) => b.markerTime.compareTo(a.markerTime));
    return deduped;
  }

  Future<Map<String, File>> _indexRecordingFiles(List<Directory> folders) async {
    final index = <String, File>{};
    for (final folder in folders) {
      try {
        await for (final entity in folder.list()) {
          if (entity is File) index.putIfAbsent(p.basename(entity.path), () => entity);
        }
      } on FileSystemException catch (_) {}
    }
    return index;
  }

  static File? _resolveMarkerSegment(Map<String, File> index, String? filename) {
    if (filename == null || filename.isEmpty) return null;
    final name = RecordingFilename.basename(filename);
    final exact = index[name];
    if (exact != null) return exact;
    final alias = name.contains('_draft.')
        ? name.replaceAll('_draft.', '.')
        : name.replaceAllMapped(RegExp(r'\.(m4a|wav|ogg)$'), (m) => '_draft${m[0]}');
    return index[alias];
  }

  Future<List<Directory>> _recordingFolders() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'recordings'));
    if (!await root.exists()) return [];
    return (await root.list().toList()).whereType<Directory>().toList();
  }

  Future<List<File>> _markerEdlFiles(List<Directory> folders) async {
    final files = <File>[];
    for (final folder in folders) {
      await for (final entity in folder.list()) {
        if (entity is File && p.basename(entity.path).startsWith('marker_') && entity.path.endsWith('.edl')) {
          files.add(entity);
        }
      }
    }
    return files;
  }

  /// Derives the date-folder name (YYYY-MM-DD) from epoch milliseconds.
  ///
  /// **Convention**: all date folders use the *local* timezone so that
  /// recordings appear under the date the user experienced them.  Session IDs
  /// and device markers use UTC internally, but folder placement is always
  /// local.  A recording that starts before midnight local time and ends after
  /// midnight is placed under the *start* date.
  static String _dateStringFromMillis(int millis) => fmtDate(DateTime.fromMillisecondsSinceEpoch(millis).toLocal());

  /// The automatic pass after a sync ([runPipelinePass]). Safe to call from a background
  /// timer; does nothing while a pass is running.
  static Future<void> processAllCompletedSessions() async {
    await runPipelinePass();
  }

  /// One pass of the new pipeline (RECORDINGS_PIPELINE_REDESIGN.md §5), then the clock
  /// pass over what it published (§8). [force] first closes what is open (Force Sync).
  /// Null when a pass was already running.
  static Future<PassReport?> runPipelinePass({bool force = false, bool reserved = false}) async {
    if (_isProcessingAny && !reserved) return null;
    _isProcessingAny = true;
    _cancelRequested = false;
    processingProgress.value = 0.0;
    try {
      final report = await AppPipeline.instance.runPass(
          force: force,
          onLiveness: () => processingLiveness.value++,
          onProgress: (done) => processingProgress.value = done);
      if (report != null) {
        // The storage pause shows what waits for space: the files of what the pass could
        // not render, until a pass gets through.
        final waiting = <String, int>{};
        if (report.stop == PassStop.storageFull) {
          for (final k in report.waiting) {
            waiting[k.rel] = (await AppPipeline.instance.coordinator.store.load(k)).length;
          }
        }
        _saveStorageWaitingBins(waiting);
      }
      await _applyClockAnchorsLogged();
      return report;
    } catch (e, st) {
      Logger.handle(e, st, message: 'RecordingsManager: the processing pass failed');
      return null;
    } finally {
      _isProcessingAny = false;
      processingProgress.value = 1.0;
      minutesRemaining = 0;
      await refreshStoragePause();
      notifyRecordingsChanged();
    }
  }

  /// Force-process all batches including the newest segment per DeviceSession.
  /// Used by the debug Force Process button — same as pressing the Process button
  /// on each batch but operates across all days at once.
  /// No-op if a process is already running.
  ///
  /// [reprocessCovered] (default false) preserves the original intent of
  /// "pressing Process on each batch": it RESPECTS coverage, so bins already
  /// owned by a recording are skipped and finalized recordings are left alone.
  /// Set it true ONLY for the adjustment-mode reset: clear the old library and
  /// rebuild from all available source bins with the current processing rules.
  static Future<void> forceProcessAll({bool reprocessCovered = false}) async {
    if (reprocessCovered) {
      await _resetAndReprocessAll();
      return;
    }
    await runPipelinePass(force: true);
  }

  /// Reprocess all (Adjustment Mode): the derived state today's reset clears, then the
  /// pipeline's reset (§7: generation advanced, the archive deleted, ownership cleared but
  /// for tombstones, a rebuild end) and a pass over what is on the phone. Raw files the
  /// gate has released are not restored from Adjustment Mode's copies.
  static Future<void> _resetAndReprocessAll() async {
    if (_isProcessingAny) throw StateError('Wait for the current processing run to finish.');
    _checkReprocessSyncIdle();
    _isProcessingAny = true;
    _cancelRequested = false;
    try {
      if (_uploadsInFlight.isNotEmpty) throw StateError('Wait for recording uploads to finish before reprocessing.');
      // Refused here, before anything is reset, when nothing would be rebuilt.
      final restored = await AppPipeline.instance.prepareReprocess();
      await _editArchive(() async {
        _checkReprocessSyncIdle();
        if (_uploadsInFlight.isNotEmpty) throw StateError('Wait for recording uploads to finish before reprocessing.');
        final prefs = SharedPreferencesUtil();
        prefs.pendingRefiles = '';
        prefs.clockCorrectionLedger = '';
        prefs.lateMergeNotices = [];
        for (final key in const [
          'sp_state',
          'sp_synced_count',
          'sp_total_count',
          'sp_minutes_remaining',
          'sp_marker_count',
          'sp_last_completed_stage',
          'sp_last_active_stage',
        ]) {
          await prefs.remove(key);
        }
        await ConnectorRegistry.forgetDeliveryHistory(prefs);
      });
      await AppPipeline.instance.reprocessAll(restored);
      await runPipelinePass(reserved: true);
      if (_cancelRequested) throw StateError('Reprocessing cancelled. Source segments have been kept.');
    } finally {
      _isProcessingAny = false;
      if (!recordingsUnsettled) notifyRecordingsChanged();
    }
  }

  /// Removes interrupted encodes and crop saves. A crop commits when its final
  /// audio is published; without that audio, discard its staged files and EDLs.
  /// Call once at app startup before processing begins.
  static Future<void> cleanupOrphanedTempFiles() async {
    return _editArchive(_cleanupOrphanedTempFiles);
  }

  /// Startup report of damage left by builds that renamed a session's raw folder
  /// when re-filing it (see the note in [_promoteSessionToDateHeld]). Changes
  /// nothing: a repair needs real examples to be tested against, so this only says
  /// whether this install has any.
  static Future<void> logMisdatedArchive() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final rawFolders = <String>[];
      final rawDir = Directory('${docs.path}/raw_segments');
      if (await rawDir.exists()) {
        await for (final entity in rawDir.list()) {
          if (entity is! Directory) continue;
          // UTC seconds stay 10 digits until 2286. Only seconds plus a millisecond
          // offset — the old rename — reach 1e11.
          final timerStart = int.tryParse(p.basename(entity.path));
          if (timerStart != null && timerStart > 100000000000) rawFolders.add(p.basename(entity.path));
        }
      }
      final days = <String>[];
      final recordingsDir = Directory('${docs.path}/recordings');
      if (await recordingsDir.exists()) {
        await for (final entity in recordingsDir.list()) {
          if (entity is! Directory) continue;
          final year = int.tryParse(p.basename(entity.path).split('-').first);
          if (year != null && year > 3000) days.add(p.basename(entity.path));
        }
      }
      if (rawFolders.isEmpty && days.isEmpty) return;
      Logger.warning('RecordingsManager: mis-dated archive left by an earlier re-file — '
          '${rawFolders.length} raw folder(s) ${rawFolders.take(5).toList()}, '
          '${days.length} recording day(s) ${days.take(5).toList()}. Left unchanged.');
    } catch (e) {
      Logger.error('RecordingsManager: mis-dated archive check failed: $e');
    }
  }

  static Future<void> _cleanupOrphanedTempFiles() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;
    final files = await recordingsDir.list(recursive: true).where((e) => e is File).cast<File>().toList();
    final remove = <String>{};
    final cropGroups = <String, List<String>>{};
    final completedStems = files
        .where((f) => const ['.wav', '.m4a', '.ogg'].contains(p.extension(f.path)) && !f.path.contains('.tmp'))
        .map((f) => RecordingFilename.stem(f.path))
        .toSet();

    void trackCrop(String path) {
      var stem = p.basenameWithoutExtension(path);
      // An Opus sidecar can be published before the crop's metadata exists.
      if (stem.startsWith('recording_fs320_')) stem = stem.replaceFirst('recording_fs320_', 'recording_');
      final prefix = stem.startsWith('recording_') ? 'recording_' : 'unknown_';
      if (!stem.startsWith(prefix)) return;
      final identity = stem.substring(prefix.length);
      final folder = p.dirname(path);
      cropGroups.putIfAbsent(
          p.join(folder, identity),
          () => [
                p.join(folder, 'recording_$identity'),
                p.join(folder, 'unknown_$identity'),
              ]);
    }

    for (final file in files) {
      final name = p.basename(file.path);
      if (name.endsWith('.tmp.m4a') || RegExp(r'^marker_\d+\.edl\.tmp$').hasMatch(name)) remove.add(file.path);
      final staged = name.endsWith('.tmp');
      final target = staged ? file.path.substring(0, file.path.length - 4) : file.path;
      final extension = p.extension(target);
      final namedCrop = RecordingFilename.cropSuffix(target).isNotEmpty;
      if (namedCrop && const ['.wav', '.m4a', '.ogg', '.meta', '.bin'].contains(extension)) {
        trackCrop(target);
        if (staged) remove.add(file.path);
      } else if (staged && extension == '.wav') {
        // Also clean up copies made by versions before crop filename suffixes.
        trackCrop(target);
        remove.add(file.path);
      } else if (staged && (extension == '.meta' || extension == '.jsonl')) {
        // An atomic rewrite killed before its rename. The target still holds the
        // last complete version, so the staged copy is only litter.
        remove.add(file.path);
      } else if (!staged && extension == '.meta') {
        final conversation = await Conversation.fromFileAsync(File(p.setExtension(file.path, '.wav')));
        if (conversation.isCropped) trackCrop(file.path);
      }
    }

    final incompleteStems = <String>{};
    for (final stems in cropGroups.values) {
      var complete = false;
      for (final stem in stems) {
        for (final extension in const ['.wav', '.m4a', '.ogg']) {
          if (await File('$stem$extension').exists()) complete = true;
        }
        // Uploaded passthrough recordings deliberately retain only metadata.
        if (!complete && await File('$stem.meta').exists()) {
          complete = (await Conversation.fromFileAsync(File('$stem.wav'))).passthrough;
        }
        if (complete) break;
      }
      if (complete) {
        completedStems.addAll(stems.map(p.basename));
        continue;
      }
      for (final stem in stems) {
        incompleteStems.add(p.basename(stem));
        for (final path in ['$stem.meta', '$stem.bin', opusFrameSidecarPathFor(File('$stem.wav'))]) {
          remove.add(path);
          remove.add('$path.tmp');
        }
      }
    }
    for (final file in files.where((f) => f.path.endsWith('.edl'))) {
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final filename = json['segmentFilename'] as String?;
        if (filename == null) continue;
        final stem = RecordingFilename.stem(filename);
        // A previous cleanup may have deleted all other crop files before it
        // reached this marker. Finished audio can also live in another folder.
        if (!completedStems.contains(stem) &&
            (incompleteStems.contains(stem) || RecordingFilename.cropSuffix(filename).isNotEmpty)) {
          remove.add(file.path);
        }
      } catch (_) {}
    }
    for (final path in remove) {
      try {
        await File(path).delete();
        Logger.debug('RecordingsManager: Removed incomplete recording file $path');
      } on FileSystemException catch (e) {
        if (await File(path).exists()) Logger.error('RecordingsManager: Failed to remove incomplete file $path: $e');
      }
    }
  }

  /// Deletes a single processed conversation and its associated meta/bin files.
  static Future<void> deleteConversation(Conversation conversation) async {
    await deleteConversations([conversation]);
  }

  /// Deletes multiple processed conversations and their associated meta/bin/marker files.
  /// Efficiently groups by directory to minimize directory listings for EDL cleanup.
  static Future<void> deleteConversations(List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    await _editArchive(() async {
      // Every explicit deletion (a row, a selection, the player) forgets delivery
      // history first. Retention forgets only files it actually removes below.
      // What was delivered stays delivered at the destination; nothing is recalled.
      await ConnectorRegistry.recordingsDeleted(conversations);
      // The ledger keeps their audio owned (§7), so it is never made into a recording
      // again; nothing else changes.
      await _deleteConversationFiles(conversations);
      Logger.debug('RecordingsManager: deleted ${conversations.length} recording(s): '
          '${conversations.take(10).map((c) => p.relative(c.file.path, from: c.file.parent.parent.path)).join(', ')}'
          '${conversations.length > 10 ? ', +${conversations.length - 10} more' : ''}');
    });
  }

  /// Skip, for a file processing keeps failing inside: set aside, so processing goes on
  /// around it (§7).
  static Future<void> skipSetAsideBin(String relBin) async {
    final key = RawFileKey.fromRel(relBin);
    if (key == null) {
      await SetAsideBins.skip(relBin);
      return;
    }
    await AppPipeline.instance.setAside(key);
    notifyRecordingsChanged();
  }

  /// Save original file: [relBin]'s logical file, its chunks in order, in a temporary file
  /// to share.
  static Future<File> exportRawFile(String relBin) async {
    final key = RawFileKey.fromRel(relBin);
    final first = await SetAsideBins.fileFor(relBin);
    if (key == null) return first;
    final out = File('${(await getTemporaryDirectory()).path}/original/${first.uri.pathSegments.last}');
    await out.parent.create(recursive: true);
    await AppPipeline.instance.exportRaw(key, out);
    return out;
  }

  static Future<void> deleteSetAsideBin(String relBin) async {
    final key = RawFileKey.fromRel(relBin);
    if (key == null) {
      SetAsideBins.release(relBin);
      return;
    }
    await AppPipeline.instance.deleteRawFile(key);
    notifyRecordingsChanged();
  }

  /// Try again, for a file processing set aside (§7): it is no longer set aside, its card
  /// is rebuilt, and a pass saves what it holds that is not saved yet. Throws
  /// [ProcessingBusy], with nothing changed, if a pass is going.
  static Future<SetAsideRetry> retrySetAsideBin(String relBin) async {
    final key = RawFileKey.fromRel(relBin);
    if (key == null || (await AppPipeline.instance.coordinator.store.load(key)).chunks.isEmpty) {
      SetAsideBins.release(relBin);
      return SetAsideRetry.gone;
    }
    if (_isProcessingAny) throw const ProcessingBusy();
    // Try again (§7): off the set-aside list, its card made again, back in its place.
    await AppPipeline.instance.tryAgain(key);
    await runPipelinePass();
    return SetAsideRetry.recovered;
  }

  /// Lists recordings and removes expired files while date correction and
  /// processing wait. Every deletion re-reads metadata and the current retention
  /// setting; unknown dates and recordings awaiting correction stay on disk.
  Future<List<Batch>> getBatchesWithRetention() async {
    await _waitForRetention();
    final prefs = SharedPreferencesUtil();
    if (prefs.keepRecordingsDays <= 0 || recordingsUnsettled) return getBatches();
    final done = Completer<void>();
    _retentionDone = done;
    var deleted = <Conversation>[];
    try {
      var batches = await getBatches();
      final cutoff = DateTime.now().subtract(Duration(days: prefs.keepRecordingsDays));
      deleted = await _deleteConversationFiles(
        batches.expand((b) => b.finalizedRecordings).where((c) => c.startTime.isBefore(cutoff)).toList(),
        shouldDelete: (c) {
          if (_isProcessingAny || _refileDepth > 0 || isUploading(c.file)) return false;
          final days = prefs.keepRecordingsDays;
          if (days <= 0) return false;
          final current = Conversation.fromFile(c.file);
          if (!c.file.existsSync() && !current.passthrough) return false;
          if (current.isUnknown || _readPendingRefiles().containsKey(_inFlightKey(c.file))) return false;
          final anchor = DeviceClockAnchorSet.decode(prefs.deviceClockAnchors).forSession(current.sessionId);
          final ledger = ClockCorrectionLedger.decode(prefs.clockCorrectionLedger);
          var startTime = current.startTime;
          if (anchor != null && !ledger.isReverted(current.sessionId ?? 0)) {
            final verdict = clockVerdict(
              anchor: anchor,
              recordedSessionId: current.sessionId,
              startUptimeSec: current.startUptime,
              claimedStartMs: current.startTime.millisecondsSinceEpoch - current.startUptimeRemainderMs,
              isUnknown: current.isUnknown,
            );
            if (verdict == ClockVerdict.correctWrong || verdict == ClockVerdict.fileUnknown) {
              if (!current.passthrough) return false;
              // Released audio has only metadata, which a re-file pass cannot
              // move. Its anchor can still establish the age of that history.
              startTime = DateTime.fromMillisecondsSinceEpoch(
                  anchor.startMsFor(current.startUptime!) + current.startUptimeRemainderMs);
            }
          }
          return startTime.isBefore(DateTime.now().subtract(Duration(days: days)));
        },
      );
      if (deleted.isNotEmpty) {
        // Forget only files actually removed. A cleanup that yielded to a clock
        // correction must also preserve the recording's delivery history.
        await ConnectorRegistry.recordingsDeleted(deleted);
        batches = await getBatches();
      }
      return batches;
    } finally {
      _retentionDone = null;
      done.complete();
      if (deleted.isNotEmpty) notifyRecordingsChanged();
    }
  }

  static Future<List<Conversation>> _deleteConversationFiles(
    List<Conversation> conversations, {
    bool Function(Conversation)? shouldDelete,
  }) async {
    final deleted = <Conversation>[];

    // On disk before any file goes: a kill mid-delete must not leave bins that
    // nothing names, or the next run decodes the recording straight back.
    // The ledger keeps their audio owned (§7): no deleted list, and nothing to prune.

    // Group conversations by directory to minimize directory listings for EDL cleanup
    final Map<String, List<Conversation>> byDir = {};
    for (final c in conversations) {
      final dir = c.file.parent.path;
      byDir.putIfAbsent(dir, () => []).add(c);
    }

    for (final dirPath in byDir.keys) {
      final convsInDir = byDir[dirPath]!;
      final filenames = <String>{};

      // 1. Delete audio, meta and Opus frame sidecar files, concurrently (each touches
      // disjoint paths).
      await Future.wait(convsInDir.map((c) async {
        if (shouldDelete != null && !shouldDelete(c)) return;
        final file = c.file;
        // Drop the exists() probe and let delete() fail-soft — one syscall per file instead of two.
        try {
          await file.delete();
        } on FileSystemException catch (_) {
          if (shouldDelete != null && !(c.passthrough && !file.existsSync())) return;
        }
        deleted.add(c);
        filenames.add(p.basename(file.path));
        final metaPath = '${file.path.substring(0, file.path.lastIndexOf('.'))}.meta';
        final metaFile = File(metaPath);
        try {
          await metaFile.delete();
        } on FileSystemException catch (_) {}
        try {
          await File(opusFrameSidecarPathFor(file)).delete();
        } catch (_) {}
      }));

      if (filenames.isEmpty) continue;

      // 2. Delete EDL files for all deleted conversations in this directory at once.
      // Reads + deletes run concurrently — each EDL is an independent JSON sidecar.
      try {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          final dirEntities = await dir.list().toList();
          await Future.wait(dirEntities.map((entity) async {
            if (entity is! File || !entity.path.endsWith('.edl')) return;
            try {
              final json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
              if (filenames.contains(json['segmentFilename'])) {
                await entity.delete();
              }
            } catch (_) {}
          }));
        }
      } catch (e) {
        Logger.error('RecordingsManager: Failed to cleanup EDLs in $dirPath: $e');
      }
    }
    return deleted;
  }

  /// Saves a cropped copy as a finalized recording with its own identity and
  /// metadata. The original audio and its upload/source-bin state stay intact.
  Future<Conversation> saveCroppedConversation(Conversation source, Duration start, Duration end) async {
    return _editArchive(() => _saveCroppedConversation(source, start, end));
  }

  /// Resolves an open player's snapshot after queued file moves have finished.
  Future<Conversation> resolveConversation(Conversation original) => _editArchive(() async {
        final folders = await _recordingFolders();
        return _currentConversation(original, await _indexRecordingFiles(folders));
      });

  Future<Conversation> _saveCroppedConversation(Conversation source, Duration start, Duration end) async {
    if (start.isNegative || end <= start) {
      throw ArgumentError('Choose a valid crop range.');
    }
    // Resolve inside the edit queue: a date correction may have moved the
    // source while its player stayed open, or while this save waited its turn.
    source = await _currentConversation(source, await _indexRecordingFiles(await _recordingFolders()));
    final docs = await getApplicationDocumentsDirectory();
    final startMs = source.startTime.add(start).millisecondsSinceEpoch;
    final folder = Directory(p.join(docs.path, 'recordings', _dateStringFromMillis(startMs)));
    await folder.create(recursive: true);
    final prefix = source.isUnknown ? 'unknown' : 'recording';
    final id = const Uuid().v4();
    final stem = '${prefix}_${startMs}_crop_$id';
    final audio = File(p.join(folder.path, '$stem.wav'));
    final temporaryAudio = File('${audio.path}.tmp');
    final meta = File(p.join(folder.path, '$stem.meta'));
    final temporaryMeta = File('${meta.path}.tmp');
    final opus = File(opusFrameSidecarPathFor(audio));
    final temporaryOpus = File('${opus.path}.tmp');
    final markerFiles = await _markerEdlFiles(await _recordingFolders());
    final markerTimes = markerFiles.map((f) => RecordingFilename.timestamp(f.path)).toSet();
    var markerMs = startMs;
    while (markerTimes.contains(markerMs)) {
      markerMs++;
    }
    final marker = File(p.join(folder.path, 'marker_$markerMs.edl'));
    final ownedFiles = [temporaryAudio, temporaryMeta, temporaryOpus];
    try {
      final result = await RecordingCropper.crop(source.file, temporaryAudio, start, end);
      if (result.duration + const Duration(milliseconds: 1) < end - start) {
        throw ArgumentError('The crop range exceeds the recording.');
      }
      final uptimeMs = source.startUptimeMs == null ? null : source.startUptimeMs! + start.inMilliseconds;
      final remainder = ByteData(4)..setUint32(0, uptimeMs == null ? 0 : uptimeMs % 1000, Endian.little);
      final header = ByteData(416)
        ..setUint32(0, result.samples, Endian.little)
        ..setUint32(4, result.duration.inMilliseconds, Endian.little)
        ..setUint32(408, source.sessionId ?? 0, Endian.little)
        ..setUint32(412, uptimeMs == null ? 0 : uptimeMs ~/ 1000, Endian.little);
      for (var i = 0; i < result.peaks.length; i++) {
        header.setUint16(8 + i * 2, result.peaks[i], Endian.little);
      }
      final key = 'crop_$id'.codeUnits;
      var flags = 0x80 | 0x02 | 0x04; // cropped, hardStart, hardEnd: never stitch a user edit
      if (source.isSilero == true) flags |= 0x01;
      if (source.recordedManual != null) flags |= 0x08 | (source.recordedManual! ? 0x10 : 0);
      if (source.clockCorrected) flags |= 0x20;
      final bins = utf8.encode('[]'); // A cropped copy does not own the original raw bins.
      final binsLength = ByteData(4)..setUint32(0, bins.length, Endian.little);
      final bytes = BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..addByte(key.length)
        ..add(key)
        ..add([0, 0, 1, flags])
        ..add(binsLength.buffer.asUint8List())
        ..add(bins)
        ..add(remainder.buffer.asUint8List());
      await temporaryMeta.writeAsBytes(bytes.takeBytes(), flush: true);
      if (ConnectorRegistry.wantsOpusFrameSidecar(SharedPreferencesUtil())) {
        await RecordingCropper.writeOpusFrames(temporaryAudio, temporaryOpus);
        await temporaryOpus.rename(opus.path);
        ownedFiles.add(opus);
      }
      await temporaryMeta.rename(meta.path);
      ownedFiles.add(meta);
      ownedFiles.add(File('${marker.path}.tmp'));
      await _writeJsonAtomic(marker, {
        'markerTimestampMs': markerMs,
        'segmentFilename': p.basename(audio.path),
        'markerOffsetMs': 0,
        'cropStartMs': 0,
        'cropEndMs': result.duration.inMilliseconds,
        'userSaved': true,
        'isHighPriority': true,
        'priorityOverride': true,
      });
      ownedFiles.add(marker);
      // Publish audio last, so a library scan cannot see a half-saved recording.
      await temporaryAudio.rename(audio.path);
      ownedFiles.add(audio);
      return await Conversation.fromFileAsync(audio);
    } catch (_) {
      for (final file in ownedFiles) {
        if (await file.exists()) await file.delete();
      }
      rethrow;
    }
  }

  /// Updates priority markers without changing ordinary bookmarks or crop edits.
  /// Removed markers remain as hidden EDLs, preserving the choice across processing,
  /// file renames and date correction through the existing EDL lifecycle.
  Future<void> setConversationPriority(Conversation conversation, bool isPriority) async {
    return _editArchive(() => _setConversationPriority(conversation, isPriority));
  }

  Future<void> _setConversationPriority(Conversation conversation, bool isPriority) async {
    final folders = await _recordingFolders();
    final index = await _indexRecordingFiles(folders);
    // A player can retain this object while background sync re-files its audio.
    // Resolve by the metadata identity inside the archive edit queue, and reject
    // deleted recordings rather than writing a marker for a path that is gone.
    conversation = await _currentConversation(conversation, index);
    final folder = conversation.file.parent;
    final filename = p.basename(conversation.file.path);
    final markerFiles = await _markerEdlFiles(folders);
    final priorityEdls = <(File, Map<String, dynamic>)>[];
    for (final entity in markerFiles) {
      Map<String, dynamic> data;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map<String, dynamic>) continue;
        data = decoded;
      } on FormatException {
        continue;
      }
      final segmentName = data['segmentFilename'];
      if (segmentName is! String) continue;
      final segment = _resolveMarkerSegment(index, segmentName);
      if (segment != null &&
          p.equals(segment.path, conversation.file.path) &&
          (data['isHighPriority'] == true || data['priorityOverride'] is bool)) {
        data['segmentFilename'] = filename;
        priorityEdls.add((entity, data));
      }
    }

    if (priorityEdls.isEmpty && isPriority) {
      // Use a distinct timestamp if a bookmark already exists at the recording start.
      // Markers are deduplicated by timestamp, so neither its file nor its ID may collide.
      var markerMs = conversation.startTime.millisecondsSinceEpoch;
      var edlFile = File(p.join(folder.path, 'marker_$markerMs.edl'));
      final usedTimestamps = markerFiles.map((f) => RecordingFilename.timestamp(f.path)).toSet();
      while (await edlFile.exists() || usedTimestamps.contains(markerMs)) {
        markerMs++;
        edlFile = File(p.join(folder.path, 'marker_$markerMs.edl'));
      }
      priorityEdls.add((
        edlFile,
        {
          'markerTimestampMs': markerMs,
          'segmentFilename': filename,
          'markerOffsetMs': markerMs - conversation.startTime.millisecondsSinceEpoch,
          'cropStartMs': 0,
          'cropEndMs': conversation.duration.inMilliseconds,
          'userSaved': false,
        }
      ));
    }

    for (final (file, data) in priorityEdls) {
      data['isHighPriority'] = isPriority;
      data['priorityOverride'] = isPriority;
      await _writeJsonAtomic(file, data);
    }
  }

  Future<Conversation> _currentConversation(Conversation original, Map<String, File> index) async {
    final key = original.uploadKey;
    final atPath = index[p.basename(original.file.path)];
    if (atPath != null && p.equals(atPath.path, original.file.path) && await atPath.exists()) {
      final current = await Conversation.fromFileAsync(atPath);
      if (key == null || key.isEmpty || current.uploadKey == key) return current;
    }
    if (key != null && key.isNotEmpty) {
      for (final file in index.values) {
        if (!const ['.wav', '.m4a', '.ogg'].contains(p.extension(file.path)) || file.path.contains('.tmp')) continue;
        final current = await Conversation.fromFileAsync(file);
        if (current.uploadKey == key && await file.exists()) return current;
      }
    }
    throw FileSystemException('Recording is no longer available.', original.file.path);
  }

  /// Deletes a marker.
  static Future<void> deleteMarkerConversation(MarkerConversation mc) async {
    if (await mc.edlFile.exists()) {
      await mc.edlFile.delete();
      Logger.debug('RecordingsManager: Deleted marker ${mc.edlFile.path}');
    }
  }

  /// Deletes processed recordings (.m4a/.wav/.meta/.bin) for a day.

  /// Safe to call while nothing is playing.
  /// Delete Day (§7): what is saved under the day goes, except what crosses midnight;
  /// nothing in progress, on the Omi or downloading. The connectors forget the
  /// recordings it deleted.
  Future<void> deleteDay(Batch batch) async {
    Batch current = batch;
    for (final b in await getBatches()) {
      if (b.dateString == batch.dateString) current = b;
    }
    final before = [...current.finalizedRecordings, ...current.draftRecordings];
    final docs = (await getApplicationDocumentsDirectory()).path.replaceAll('\\', '/');
    final deleted = (await AppPipeline.instance.deleteDay(batch.dateString)).toSet();
    String rel(String path) => path.replaceAll('\\', '/').substring(docs.length + 1);
    final gone = [
      for (final c in before)
        if (deleted.contains(rel(c.file.path)) || deleted.contains(rel(p.setExtension(c.file.path, '.meta')))) c
    ];
    if (gone.isNotEmpty) await ConnectorRegistry.recordingsDeleted(gone);
    notifyRecordingsChanged();
  }

  /// Sets flag byte [3] bit 0x20 on [meta] — "the phone re-filed this".
  ///
  /// Read-modify-write of a single bit rather than a rewrite of the sidecar: the
  /// bins-JSON tail is located from the meta's own length, so anything that changes the
  /// length shifts that tail out from under every reader. Flag byte [3] already exists
  /// on any `.meta` this can be called for (the processor writes all four), so no byte
  /// is being added. A fifth flag byte would shift the length-inferred bins-JSON tail.
  ///
  /// Best-effort: a meta too short to carry flags means a recording written by an older
  /// build or a torn write. The move still happened and is still right; all that is lost
  /// is the revert arrow, so this logs and returns rather than failing the correction.
  static Future<void> _stampClockCorrected(File meta) async {
    try {
      if (!await meta.exists()) return;
      final bytes = await meta.readAsBytes();
      if (bytes.length < 417) return;
      final flagOffset = 417 + bytes[416];
      if (bytes.length <= flagOffset + 3) {
        Logger.debug('RecordingsManager: ${meta.path} has no flag byte [3]; re-filed but not markable.');
        return;
      }
      if ((bytes[flagOffset + 3] & 0x20) != 0) return;
      bytes[flagOffset + 3] |= 0x20;
      await AtomicFile.writeBytes(meta, bytes);
    } catch (e) {
      Logger.error('RecordingsManager: failed to stamp clock-corrected flag on ${meta.path}: $e');
    }
  }

  /// Re-files recordings whose timestamps the Omi got wrong, using the phone as the
  /// clock of record. Returns the number of sessions moved.
  ///
  /// The Omi has no clock. It learns the time from a phone and forgets it on every
  /// restart, and the counter it falls back to is 24-bit at 6.4 ms — it wraps every
  /// ~29.8 h in the direction that makes a long gap look SHORT. So a device left off for
  /// 31 h comes back believing 1.2 h passed and files a day of audio under a confidently
  /// wrong date, with nothing on the device able to contradict it.
  ///
  /// The phone can, for any session it saw running: an anchor pairs that session's
  /// uptime with real wall-clock time, and every recording's `.meta` carries the uptime
  /// it started at, which places the whole session exactly.
  ///
  /// Three rules, in [clockVerdict]:
  ///   - a recording whose own timestamp already agrees is never touched;
  ///   - one with no timestamp at all is given one;
  ///   - one the anchor can PROVE wrong is overwritten.
  /// The gap between "a bit of drift" and "the counter wrapped" is four orders of
  /// magnitude, so no tuned threshold decides this.
  ///
  /// Only the recordings the anchor proves wrong (or that never had a time) move — not
  /// the whole session. A session has one TRUE offset, but a boot the Omi guessed wrong
  /// holds two claimed ones: everything before the phone first reached it carries the
  /// guess, everything after carries the phone's time. Re-filing every recording with
  /// the session id renamed the correct ones too (by up to a second, since uptimes are
  /// whole seconds), stamped them 0x20, and handed undo an offset that was never theirs
  /// — so undo moved them onto the Omi's wrong date. A session with no anchor — one
  /// that had already ended before the phone ever saw it — is left alone, since the
  /// gap between two boots is unmeasurable once both counters reset.
  ///
  /// Idempotent by construction. Once moved, a session's recordings agree with their
  /// anchor, so the next pass reads `alreadyCorrect` and does nothing; and a user who
  /// reverts drops the anchor, so nothing re-applies it.
  static Future<int> applyClockAnchors() async {
    // Held for the whole pass, not per rename: a sweep that lists between two sessions'
    // moves would queue the second under names it is about to lose.
    _refileDepth++;
    try {
      await _waitForRetention();
      // Re-files that waited for an upload but never got applied — the app was killed
      // before the upload ended. Every sync runs this pass, so none waits past one.
      await _applyDeferredRefiles();
      return await _applyClockAnchorsHeld();
    } finally {
      _refileDepth--;
      if (!recordingsUnsettled) notifyRecordingsChanged();
    }
  }

  static Future<int> _applyClockAnchorsHeld() async {
    final prefs = SharedPreferencesUtil();
    final anchors = DeviceClockAnchorSet.decode(prefs.deviceClockAnchors);
    if (anchors.isEmpty) return 0;
    var ledger = ClockCorrectionLedger.decode(prefs.clockCorrectionLedger);

    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return 0;

    // Group this session's finalized recordings. Drafts are skipped: they are still
    // being appended to and are not surfaced, and the pass that promotes them will
    // produce a finalized file this can correct on a later run.
    final bySession = <int, List<Conversation>>{};
    for (final folder in (await recordingsDir.list().toList()).whereType<Directory>()) {
      for (final f in (await folder.list().toList()).whereType<File>()) {
        final path = f.path;
        if (!(path.endsWith('.m4a') || path.endsWith('.wav') || path.endsWith('.ogg'))) continue;
        if (path.contains('_draft.')) continue;
        final conv = Conversation.fromFile(f);
        final sid = conv.sessionId;
        if (sid == null || sid == 0) continue;
        if (anchors.forSession(sid) == null) continue;
        // The user undid this session's correction. Their decision outranks the anchor,
        // and permanently: the anchor is re-observed on every connect while the Omi stays
        // on this boot, so without this the very next pass would re-file the session and
        // silently reverse them.
        if (ledger.isReverted(sid)) continue;
        bySession.putIfAbsent(sid, () => []).add(conv);
      }
    }

    var moved = 0;
    for (final entry in bySession.entries) {
      final anchor = anchors.forSession(entry.key)!;
      final convs = entry.value;

      final toMove = <Conversation>[];
      for (final c in convs) {
        final verdict = clockVerdict(
          anchor: anchor,
          recordedSessionId: c.sessionId,
          startUptimeSec: c.startUptime,
          claimedStartMs: c.startTime.millisecondsSinceEpoch - c.startUptimeRemainderMs,
          isUnknown: c.isUnknown,
        );
        if (verdict == ClockVerdict.correctWrong || verdict == ClockVerdict.fileUnknown) toMove.add(c);
      }
      if (toMove.isEmpty) continue;

      // The base supplies the offset the moved recordings carried (for the ledger) and
      // converts the anchor into promoteSessionToDate's terms. Drawn from the recordings
      // being moved, never the whole session: its correct recordings carry a different
      // offset, and undo must restore the one these had. Both verdicts above require a
      // usable uptime, so every candidate has one; the earliest is chosen so the
      // folder-migration step keys off the first of them.
      var base = toMove.first;
      for (final c in toMove) {
        if (c.startUptimeMs! < base.startUptimeMs!) base = c;
      }
      final movePaths = {for (final c in toMove) c.file.path};

      final newStartMs = anchor.startMsFor(base.startUptime!) + base.startUptimeRemainderMs;
      // Captured BEFORE the move, because the move is what destroys it: the offset lives
      // only in the filenames, and promoteSessionToDate rewrites them. Without this an
      // undo has nothing to restore.
      final originalOffsetMs = base.startTime.millisecondsSinceEpoch - base.startUptimeMs!;
      try {
        await promoteSessionToDate(
          base,
          DateTime.fromMillisecondsSinceEpoch(newStartMs),
          markClockCorrected: true,
          include: (c) => movePaths.contains(c.file.path),
        );
        ledger = ledger.recordCorrection(entry.key, originalOffsetMs);
        prefs.clockCorrectionLedger = ledger.encode();
        moved++;
        Logger.debug('RecordingsManager: clock anchor re-filed ${toMove.length} of ${convs.length} recording(s) '
            'in session ${entry.key}, from ${DateTime.fromMillisecondsSinceEpoch(newStartMs)}');
      } catch (e) {
        Logger.error('RecordingsManager: clock-anchor re-file failed for session ${entry.key}: $e');
      }
    }
    return moved;
  }

  /// Undoes [applyClockAnchors] for one session, and discards the anchor that did it.
  ///
  /// Dropping the anchor is not tidy-up, it is the point: leave it in place and the very
  /// next processing pass reads the same verdict, re-files the session, and silently
  /// undoes the user's decision. The anchor is the correction's authority, so revoking
  /// the correction has to revoke the authority.
  static Future<void> revertClockCorrection(Conversation conv) async {
    _refileDepth++;
    try {
      await _waitForRetention();
      await _revertClockCorrectionHeld(conv);
    } finally {
      _refileDepth--;
      if (!recordingsUnsettled) notifyRecordingsChanged();
    }
  }

  static Future<void> _revertClockCorrectionHeld(Conversation conv) async {
    final sessionId = conv.sessionId;
    if (sessionId == null || sessionId == 0) return;

    final prefs = SharedPreferencesUtil();

    // Both halves are needed, and dropping the anchor is the lesser one. The anchor comes
    // straight back on the next diagnostics read — every reconnect, while the Omi stays on
    // this boot — so only the ledger entry makes the rejection stick.
    prefs.deviceClockAnchors = DeviceClockAnchorSet.decode(prefs.deviceClockAnchors).without(sessionId).encode();
    final ledger = ClockCorrectionLedger.decode(prefs.clockCorrectionLedger);
    prefs.clockCorrectionLedger = ledger.markReverted(sessionId).encode();

    final uptime = conv.startUptimeMs;
    // The offset these recordings carried before the app moved them. It cannot be derived
    // now — the move rewrote the filenames it lived in — so a session with no ledger entry
    // is one this build cannot put back, and saying so beats inventing a date. (Reading
    // the uptime as an epoch, which an earlier version of this did, lands in 1970 rather
    // than on whatever the Omi had filed.)
    final originalOffsetMs = ledger.originalOffsetFor(sessionId);
    if (uptime == null || uptime <= 0 || originalOffsetMs == null) {
      Logger.debug('RecordingsManager: session $sessionId marked as user-rejected, but its original '
          'timestamps are not recorded — files left where they are.');
      notifyRecordingsChanged();
      return;
    }
    // Only what the correction moved. The rest of the session was never re-filed, and
    // the ledger's offset is not theirs: applying it would move correctly-dated
    // recordings onto the Omi's wrong date. A session corrected by an older build that
    // re-filed whole sessions carries 0x20 on its correct recordings too, and nothing
    // left on disk tells those apart — their original names are gone.
    await promoteSessionToDate(conv, DateTime.fromMillisecondsSinceEpoch(uptime + originalOffsetMs),
        include: (c) => c.clockCorrected);
    await _clearClockCorrectedForSession(sessionId);
    notifyRecordingsChanged();
  }

  /// Clears bit 0x20 across a session, so the revert arrow disappears with the revert.
  static Future<void> _clearClockCorrectedForSession(int sessionId) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;
    for (final folder in (await recordingsDir.list().toList()).whereType<Directory>()) {
      for (final f in (await folder.list().toList()).whereType<File>()) {
        if (!f.path.endsWith('.meta')) continue;
        try {
          final bytes = await f.readAsBytes();
          if (bytes.length < 417) continue;
          final bd = ByteData.sublistView(bytes);
          if (bd.getUint32(408, Endian.little) != sessionId) continue;
          final flagOffset = 417 + bytes[416];
          if (bytes.length <= flagOffset + 3) continue;
          if ((bytes[flagOffset + 3] & 0x20) == 0) continue;
          bytes[flagOffset + 3] &= ~0x20;
          await AtomicFile.writeBytes(f, bytes);
        } catch (_) {}
      }
    }
  }

  /// Batch-updates the starting timestamp for a hardware session's recordings.
  ///
  /// This renames and moves the processed recordings, .meta sidecars, .bin raw syncs,
  /// and .edl markers belonging to the same sessionId — every one of them, or only
  /// those [include] accepts. Every caller passes [include], because a session's
  /// recordings need not share an offset: a boot the Omi guessed wrong is wrong only
  /// until the phone first reaches it. The offset itself is derived from [base].
  /// [markClockCorrected] stamps flag byte [3] bit 0x20 on every `.meta` this moves,
  /// marking the recording as re-filed by the phone rather than timestamped by the Omi.
  /// Only [applyClockAnchors] passes it — the manual date picker leaves the bit alone,
  /// because a date the user chose by hand has nothing to revert *to*.
  static Future<void> promoteSessionToDate(Conversation base, DateTime newStartTime,
      {bool markClockCorrected = false, bool Function(Conversation c)? include}) async {
    return _editArchive(
        () => _promoteSessionToDateHeld(base, newStartTime, markClockCorrected: markClockCorrected, include: include));
  }

  static Future<void> _promoteSessionToDateHeld(Conversation base, DateTime newStartTime,
      {required bool markClockCorrected, bool Function(Conversation c)? include}) async {
    final sessionId = base.sessionId;
    final startUptime = base.startUptimeMs;
    if (startUptime == null || startUptime == 0) {
      throw Exception('Cannot promote session: startUptime is missing or zero.');
    }

    final rtcOffsetMs = newStartTime.millisecondsSinceEpoch - startUptime;
    final directory = await getApplicationDocumentsDirectory();

    // 1. Identify all affected finalized recordings across all date folders.
    final List<Conversation> sessionConversations = [];
    final recordingsDir = Directory('${directory.path}/recordings');
    final markerFolders = await _instance._recordingFolders();
    final filenameIndex = await _instance._indexRecordingFiles(markerFolders);
    final markerFiles = await _instance._markerEdlFiles(markerFolders);
    final usedMarkerTimes = markerFiles.map((f) => RecordingFilename.timestamp(f.path)).toSet();
    if (await recordingsDir.exists()) {
      final dateFolders = (await recordingsDir.list().toList()).whereType<Directory>().toList();
      for (final folder in dateFolders) {
        final audioFiles = await folder
            .list()
            // A `_draft.` is still being appended to and is not a finalized recording.
            // Renaming it strips the suffix, promoting a partial into the UI and
            // stranding its tail — the premature promotion the background flush path
            // is careful never to do. [applyClockAnchors] already excludes drafts when
            // it decides; this is the half that used to move them anyway.
            .where(
                (e) => e is File && (e.path.endsWith('.m4a') || e.path.endsWith('.wav')) && !e.path.contains('_draft.'))
            .cast<File>()
            .toList();

        for (final file in audioFiles) {
          final conv = Conversation.fromFile(file);
          final inSession = (conv.sessionId == sessionId && sessionId != null) ||
              // Fallback for single-file promotion if sessionId is missing
              file.path == base.file.path;
          if (inSession && (include == null || include(conv))) sessionConversations.add(conv);
        }
      }
    }

    // Deterministic order, because step 2 below has a winner and a loser. Two
    // recordings that share a `startUptime` derive the same target name, one claims it
    // and the other is left under the Omi's own timestamp — and until this sort, which
    // one that was came out of `Directory.list()`, i.e. readdir order. Same data, same
    // code, different outcome on a different phone or after the files are rewritten,
    // and nothing to point at when a user asks why *that* recording kept a wrong date.
    //
    // Earliest first, so the claim goes to the oldest recording in the session. That is
    // the one [applyClockAnchors] anchors the whole correction on (it picks the lowest
    // uptime as `base`, and every target here is derived from its offset), so it is the
    // recording the correction is least defensible in refusing.
    sessionConversations.sort((a, b) {
      final byStart = a.startTime.compareTo(b.startTime);
      // Same-instant names still have to break a tie, or the sort is only mostly a sort.
      return byStart != 0 ? byStart : a.file.path.compareTo(b.file.path);
    });

    // 2. Perform renames and moves for processed recordings
    //
    // Every target here is derived from `convUptime`, which the `.meta` stores in whole
    // SECONDS — so two recordings that share an uptime derive the same filename, and
    // `File.rename` replaces its destination without a word. That is unrecoverable
    // audio loss, and it is reachable whenever a session holds recordings with equal or
    // missing uptimes. Claim each target and leave a colliding recording exactly where
    // it is: a recording under the Omi's own timestamp is worth incomparably more than
    // one re-filed onto a name that costs another recording.
    // target name -> the recording that claimed it, so a refusal can say which one.
    final claimedTargets = <String, String>{};
    // Old start -> new start of every recording actually renamed, for
    // [_remapLateMergeNotices].
    final renamedStarts = <int, int>{};
    for (final conv in sessionConversations) {
      // An upload is reading this recording right now. Omi's upload records its progress
      // under the file's current path as it goes, so renaming mid-upload lands the final
      // "delivered" mark on a path no recording has any more, and the renamed recording
      // is sent again. Deferred, not dropped: applied the moment the last upload reading
      // it ends ([_deferRefile]) — a date set by hand included.
      if (isUploading(conv.file)) {
        _deferRefile(conv.file, rtcOffsetMs, markClockCorrected);
        Logger.debug('RecordingsManager: ${conv.file.path.split('/').last} is being uploaded — '
            're-filing it once the upload ends.');
        continue;
      }
      // No usable uptime means the offset cannot place this recording — the same thing
      // `clockVerdict` calls `unplaceable` and refuses to act on. It used to fall back
      // to reading the recording's epoch SECONDS as if they were an uptime, which lands
      // it in the year 2083; a 0 (what `.meta` byte 412 holds when the processor never
      // established one) lands every such recording on the session's boot instant, all
      // under one name. Leave it where the Omi filed it.
      final convUptime = conv.startUptime ?? 0;
      if (convUptime <= 0) {
        Logger.debug('RecordingsManager: ${conv.file.path.split('/').last} has no start uptime — '
            'left under its original timestamp.');
        continue;
      }
      final newConvStartMs = conv.startUptimeMs! + rtcOffsetMs;
      final newDateStr = _dateStringFromMillis(newConvStartMs);
      final targetDir = Directory('${directory.path}/recordings/$newDateStr');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final extension = conv.file.path.split('.').last;
      var suffix = RecordingFilename.cropSuffix(conv.file.path);
      if (conv.isCropped && suffix.isEmpty) {
        // Copies saved before suffixes existed get their existing stable ID.
        final key = conv.uploadKey;
        suffix = '_crop_${key != null && key.startsWith('crop_') ? key.substring(5) : const Uuid().v4()}';
      }
      final targetStem = 'recording_$newConvStartMs$suffix';
      final newAudioPath = '${targetDir.path}/$targetStem.$extension';
      final newMetaPath = '${targetDir.path}/$targetStem.meta';
      final basePath = conv.file.path.substring(0, conv.file.path.lastIndexOf('.'));

      // Never rename onto an in-pass claim or an existing audio/meta slot. Check metadata as well as audio:
      // different audio extensions share recording_X.meta, so a WAV could overwrite an M4A's metadata without
      // colliding with its audio path.
      //
      // Log the blocker to distinguish duplicate startUptime values within this session from a slot occupied by
      // a recording outside this pass.
      final claimedBy = claimedTargets[targetStem];
      final audioInTheWay =
          claimedBy == null && !p.equals(newAudioPath, conv.file.path) && await File(newAudioPath).exists();
      final metaInTheWay = claimedBy == null &&
          !audioInTheWay &&
          !p.equals(newMetaPath, '$basePath.meta') &&
          await File(newMetaPath).exists();
      // The Opus frame sidecar is named by the recording too, so it is part of the
      // slot. If this recording has one and a different one already sits at the target,
      // moving the audio would tie the renamed recording to a file that is not its audio
      // — a connector would be sent the wrong recording — and orphan its own. A target
      // sidecar with none of ours to move does not block: it is most likely this
      // recording's own, orphaned under its original name by a build that did not move
      // sidecars with a rename, and an undo is exactly what reunites them.
      final fromBin = opusFrameSidecarPathFor(conv.file);
      final toBin = opusFrameSidecarPathFor(File(newAudioPath));
      final binInTheWay = claimedBy == null &&
          !audioInTheWay &&
          !metaInTheWay &&
          toBin != fromBin &&
          await File(fromBin).exists() &&
          await File(toBin).exists();
      if (claimedBy != null || audioInTheWay || metaInTheWay || binInTheWay) {
        final blocker = claimedBy != null
            ? 'this pass is already moving $claimedBy onto that name — the two share a startUptime'
            : audioInTheWay
                ? 'recording_$newConvStartMs.$extension is already on disk'
                : metaInTheWay
                    ? 'recording_$newConvStartMs.meta is already on disk (a different extension holds the slot)'
                    : 'recording_fs320_$newConvStartMs.bin is already on disk (an Opus frame sidecar with no recording)';
        Logger.error('RecordingsManager: refusing to re-file ${conv.file.path.split('/').last} onto '
            'recording_$newConvStartMs (startUptime=$convUptime) — $blocker. '
            'Left under its original timestamp.');
        continue;
      }
      claimedTargets[targetStem] = p.basename(conv.file.path);

      final metaFile = File('$basePath.meta');

      // Update .meta content with new UTC time if we were to be super thorough,
      // but fromFile relies on filename timestamp, so renaming the file is enough.

      if (await metaFile.exists()) await metaFile.rename(newMetaPath);
      await conv.file.rename(newAudioPath);
      renamedStarts[_extractTimestamp(conv.file.path)] = newConvStartMs;
      await _moveOpusFrameSidecar(conv.file, File(newAudioPath));
      if (markClockCorrected) await _stampClockCorrected(File(newMetaPath));

      // Handle legacy .bin sidecar if present
      final oldBinPath = '$basePath.bin';
      if (await File(oldBinPath).exists()) {
        final newBinPath = '${targetDir.path}/$targetStem.bin';
        await File(oldBinPath).rename(newBinPath);
      }

      // 3. Re-anchored EDLs may still live in another date folder or reference
      // the old draft name. Resolve them just as the marker loader does.
      for (final edlFile in markerFiles) {
        try {
          if (!await edlFile.exists()) continue;
          final content = await edlFile.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final segmentFilename = json['segmentFilename'] as String?;
          final segment = _resolveMarkerSegment(filenameIndex, segmentFilename);
          if (segment != null && p.equals(segment.path, conv.file.path)) {
            final oldMarkerMs = json['markerTimestampMs'] as int;
            final shiftMs = newConvStartMs - conv.startTime.millisecondsSinceEpoch;
            var newMarkerMs = oldMarkerMs + shiftMs;
            var newEdlFile = File('${targetDir.path}/marker_$newMarkerMs.edl');
            while ((newMarkerMs != oldMarkerMs && usedMarkerTimes.contains(newMarkerMs)) ||
                (!p.equals(newEdlFile.path, edlFile.path) && await newEdlFile.exists())) {
              newMarkerMs++;
              newEdlFile = File('${targetDir.path}/marker_$newMarkerMs.edl');
            }

            final updatedJson = Map<String, dynamic>.from(json);
            updatedJson['markerTimestampMs'] = newMarkerMs;
            updatedJson['segmentFilename'] = p.basename(newAudioPath);

            await writeJsonAtomic(newEdlFile, updatedJson);
            if (!p.equals(edlFile.path, newEdlFile.path)) await edlFile.delete();
            usedMarkerTimes.add(newMarkerMs);
          }
        } catch (e) {
          Logger.error('RecordingsManager: Failed to migrate EDL ${edlFile.path}: $e');
        }
      }
    }

    if (renamedStarts.isNotEmpty) _remapLateMergeNotices(renamedStarts);

    // Raw bins are left exactly where they are. A re-file changes when a recording
    // happened, not which bins it came from, and every reference to a bin — the
    // metas' relativeBins, the WAL's resume target, the checkpoint's refs — names
    // its original path. Renaming the session folder here (as earlier builds did, in
    // mixed seconds and milliseconds) orphaned those references: the bins were
    // re-decoded under impossible far-future dates, and a half-downloaded one was
    // fetched again from 0.

    notifyRecordingsChanged();
  }

  // --- Discard ledger (delegated to DiscardStore) ----------------------------

  /// Today's pipeline excluded discarded bins from processing; the new one plans from the
  /// ledger, so nothing is excluded this way.
  static Future<Set<String>> discardedRelBinPaths() async => const {};

  static Future<List<DiscardRecord>> getDiscardsForDate(String dateString) =>
      DiscardStore.getDiscardsForDate(dateString);

  /// Delete Discard (§7): the records go, their audio becomes a derived deletion. Without
  /// [deleteBins] (the old Recover's cleanup) nothing is left to do: Recover replaces them.
  static Future<void> removeDiscardRecord(DiscardRecord d, {required bool deleteBins}) async {
    if (!deleteBins) return;
    await AppPipeline.instance.deleteDiscards(d.pipelineIds);
    notifyRecordingsChanged();
  }

  /// Where earlier builds kept the raw files of discarded clips. The update moves them
  /// back to `raw_segments/` (LegacyUpdate); the debug tools still list what is left.
  static const String discardedSegmentsDirName = 'discarded_segments';

  /// The raw files no recording needs any more, for the "to process" estimate. The ledger
  /// knows what is owned and the gate releases those files, so none is listed here.
  static Future<Set<String>> coveredBinPaths(List<File> candidates) async => const {};
}
