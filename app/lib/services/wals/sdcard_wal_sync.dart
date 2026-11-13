import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/wal_file_manager.dart';

import 'package:path_provider/path_provider.dart';

import 'package:disk_space_2/disk_space_2.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/errors.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/raw/chunk_download.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/wals/wal_sync_exceptions.dart';

class SDCardWalSyncImpl implements SDCardWalSync {
  List<Wal> _wals = <Wal>[];

  /// When and on which link ([DeviceConnection.link]) the sync took the complete listing
  /// [_wals] came from. Null when they came from anywhere else (saved state, a listing
  /// another caller took, a partial one): the pipeline then finds no session newly ended
  /// from them ([rawFileState]). [linkSinceMs] is when that link came up
  /// ([DeviceConnection.linkSinceMs]): what the list shows the Omi held then.
  ({int atMs, int link, int linkSinceMs})? _listedOn;
  BtDevice? _device;

  final Future<DeviceConnection?> Function(String deviceId)? _connectionProvider;

  /// Test-only replacement for DeviceService.recycleConnection. Without it every
  /// recycle this class asks for is untestable: tests inject [_connectionProvider]
  /// and have no real DeviceService, so the default is withheld whenever they do.
  final Future<bool> Function()? _recycleConnectionOverride;

  Future<bool> Function()? get _recycleConnection =>
      _recycleConnectionOverride ??
      (_connectionProvider == null ? () => ServiceManager.instance().device.recycleConnection() : null);

  /// Whether a silent storage reply channel may still earn a reconnect. See
  /// [_recoverStorageReplies]; cleared by the recovery it licenses, re-armed by any
  /// reply from the device. In memory on purpose: a new process is a new link anyway.
  bool _storageRecoveryArmed = true;

  final Duration _inactivityTimeout;

  StreamSubscription? _storageStream;

  IWalSyncListener listener;

  bool _isCancelled = false;
  bool _isSyncing = false;
  int _lastSegmentBoundaryOffset = 0;
  // The STOP after the last native read failed while that read was ending on an
  // integrity gap. The firmware may still be streaming the old file, so no new read may
  // start this cycle. Set and cleared by _readStorageBytesToFileLockedNative.
  bool _stopFailedAfterIntegrityGap = false;
  // The last native read ended on an integrity gap at the same offset as the one before
  // it. Only such a gap counts against the file: one lost packet is the link's doing.
  // Set and cleared by _readStorageBytesToFileLockedNative.
  bool _integrityGapRepeated = false;
  // Absolute path of the .bin the native downloader is currently writing, or null
  // between transfers. Exposed (statted fresh) via [activeTransferBytesOnDisk] so
  // the stall watchdog sees real intra-file progress under background throttling.
  String? _activeDownloadPath;

  /// The Omi resent bytes that differ from what the phone sealed for a file: the app sets
  /// it aside ("differs from the Omi's copy"). Set by the new pipeline's wiring.
  static Future<void> Function(RawFileKey key)? onSourceMismatch;

  /// Parts a crash left are sealed once per process, before the first download: by the
  /// app's startup (AppPipeline, from the saved progress, before any listing replaces it),
  /// or here when that did not run.
  static bool partsRecovered = false;

  /// Awaited before a listing is applied: the app's startup work (the update from an
  /// earlier build) comes before any download.
  static Future<void> Function()? beforeSealedSync;

  RawChunkStore? _rawStoreCache;

  Future<RawChunkStore> _rawStore() async =>
      _rawStoreCache ??= RawChunkStore((await getApplicationDocumentsDirectory()).path);

  static RawFileKey _keyOf(Wal w) => RawFileKey(w.timerStart, w.sessionId);
  Completer<void>? _activeTransferCompleter;
  Completer<void>? _cancelCompleter;
  IWalSyncProgressListener? _globalProgressListener;

  @override
  bool get isSyncing => _isSyncing;
  @override
  bool get isSyncInFlight => _inFlightFullSync != null;
  @override
  bool get hasDevice => _device != null;

  /// Completes when [setDevice] has registered a device, so a caller that wants
  /// to sync on connect can WAIT for the WAL layer to be usable instead of firing
  /// at a guessed delay and skipping when it guesses short. Reset to a fresh
  /// pending future by `setDevice(null)`, so it tracks the current attachment
  /// rather than latching on the first device ever seen.
  Completer<void> _deviceReady = Completer<void>();
  @override
  Future<void> get deviceReady => _deviceReady.future;
  @override
  bool get isDeviceRecordingFailed => false;
  @override
  Future<void>? get cancelFuture => _cancelCompleter?.future;
  @override
  int? get activeTransferBytesOnDisk {
    final p = _activeDownloadPath;
    if (p == null) return null;
    try {
      final f = File(p);
      return f.existsSync() ? f.lengthSync() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void setGlobalProgressListener(IWalSyncProgressListener? listener) {
    _globalProgressListener = listener;
  }

  int _totalBytesDownloaded = 0;
  DateTime? _downloadStartTime;
  double _currentSpeedKBps = 0.0;

  // Canonical sync progress for the current session — the SINGLE source both the
  // recordings card and the foreground-service notification read, so they can't
  // disagree. `_syncProgressFraction` is the last reported 0..1 progress across the
  // batch; `totalSegments`/`syncedSegments` (below) derive the displayed pair from
  // it + the peak segment count, and persist across the native downloader's silent
  // inter-file gaps instead of resetting to 0. Cleared in _resetSyncState().
  double _syncProgressFraction = 0.0;
  int _syncSessionTotal = 0;
  DateTime? _lastWalPersistAt;
  static const Duration _walPersistInterval = Duration(seconds: 1);

  // When processing stops waiting for a file that keeps failing and decodes the newer
  // audio of its boot without it — see [heldBackBinRelPaths]. Whichever comes first:
  //  - [heldBackGiveUpAfter] from the file's first failure, a set time so the wait does not
  //    depend on the sync schedule. It ends at the first sync after it: the third at
  //    30-minute syncs (1.5 h), the second at hourly ones (2 h), the next at 2-hour ones. A
  //    little over the hour, so a sync landing right on it doesn't count. It also bounds a
  //    file that inches forward on every sync and so never fails "without progress".
  //  - [heldBackGiveUpFailures] syncs in a row that fail to move the file forward, so a few
  //    manual syncs in quick succession don't have to wait out the clock.
  // The file itself is never given up on: it stays on the Omi and is retried every sync,
  // since only a complete download may delete it there.
  static const Duration heldBackGiveUpAfter = Duration(minutes: 75);
  static const int heldBackGiveUpFailures = 3;

  /// Whether processing has stopped waiting for [w] (see [heldBackGiveUpAfter]). Such a
  /// file is still retried every sync, but it no longer makes a sync partial: its audio is
  /// no longer held for, so nothing a sync could finish depends on it, and counting it kept
  /// every sync "Partial" and Force Sync out of force mode for as long as it stayed stuck.
  /// It is reported on its own instead ([SharedPreferencesUtil.lastSyncStuckFiles]).
  static bool givenUpOn(Wal w, int nowMs) {
    final failingSince = w.failingSinceMs;
    return w.syncFailCount >= heldBackGiveUpFailures ||
        (failingSince != null && nowMs - failingSince >= heldBackGiveUpAfter.inMilliseconds);
  }

  // Files failing back to back in one cycle before the cycle stops. One bad file is
  // skipped; several in a row say the device or link is unwell, and the next cycle is
  // the better time to try again.
  static const int _maxFailuresInARow = 3;

  // How far before a repeated integrity gap the next native read resumes. The
  // firmware cuts packets from the requested offset, so resuming exactly at the
  // accepted prefix asks for the identical packet again. One packet observed lost on
  // every attempt — across reconnects and an Omi reboot, and also when the read
  // started one packet earlier — while the same bytes arrived in packets cut half a
  // packet earlier. Half of the 440-byte full-MTU packet moves every later boundary;
  // a multiple of 4 like every other offset the app requests.
  static const int integrityRealignBytes = 220;

  // Append each integrity gap to <documents>/packet_gap_captures/log.jsonl. After a repeated gap triggers
  // realignment, preserve the completed bin before device deletion and processing so the lost bytes can be
  // examined. Bound captures so a bad link cannot fill the phone.
  static const String packetGapCaptureDir = 'packet_gap_captures';
  static const int maxPacketGapCaptures = 10;
  static const int _packetGapHexMaxBytes = 2048;
  @override
  double get currentSpeedKBps => _currentSpeedKBps;

  @override
  int get recordingsCount => _wals.length;

  @override
  int get estimatedTotalSegments {
    if (_isSyncing) {
      return _wals
          .where(
            (w) => w.isSyncing || (w.status == WalStatus.miss && w.storage == WalStorage.sdcard),
          )
          .length;
    }
    final pending = _wals
        .where(
          (w) => w.status == WalStatus.miss && w.storage == WalStorage.sdcard,
        )
        .toList();
    return pending.length;
  }

  @override
  int get totalSegments {
    if (!_isSyncing) return 0;
    // Monotonic peak: estimatedTotalSegments shrinks as files finish + delete, but
    // the "of N" denominator must not count down. Float it up and hold the peak.
    final est = estimatedTotalSegments;
    if (est > _syncSessionTotal) _syncSessionTotal = est;
    return _syncSessionTotal;
  }

  @override
  int get syncedSegments {
    final total = totalSegments;
    if (total == 0) return 0;
    // Floor, not round: a segment counts as synced only once it fully completes (the
    // fraction crosses its boundary), so mid-transfer batch progress can't tick the
    // "N of M" counter forward past a file that's still downloading.
    final s = (_syncProgressFraction * total).floor();
    return s < 0 ? 0 : (s > total ? total : s);
  }

  SDCardWalSyncImpl(
    this.listener, {
    Future<DeviceConnection?> Function(String deviceId)? connectionProvider,
    Duration inactivityTimeout = const Duration(seconds: 15),
    @visibleForTesting bool? reconcileResumeOffsets,
    @visibleForTesting bool? useNativeDownload,
    @visibleForTesting Future<bool> Function()? recycleConnection,
  })  : _connectionProvider = connectionProvider,
        _recycleConnectionOverride = recycleConnection,
        _inactivityTimeout = inactivityTimeout,
        _reconcileResumeOverride = reconcileResumeOffsets,
        _nativeDownloadOverride = useNativeDownload;

  /// Whether the native whole-file downloader handles transfers on this platform.
  /// Single source of truth: it picks the download path AND decides whether
  /// walOffset may be reconciled against the bin on disk, so the two can't drift.
  static bool get _platformUsesNativeDownload => Platform.isAndroid || Platform.isIOS;
  final bool? _nativeDownloadOverride;
  bool get _usesNativeDownload => _nativeDownloadOverride ?? _platformUsesNativeDownload;

  bool _isStorageIntegrityError(Object e) => e is PlatformException && e.code == 'storage-integrity';

  /// Test-only override for [_shouldReconcileResume]. Tests run on the host VM,
  /// which is never Android/iOS, so without this the reconciliation — which only
  /// ever runs in production — would be impossible to cover. Never set outside tests.
  final bool? _reconcileResumeOverride;

  /// Whether walOffset tracks the PHYSICAL length of the local bin, and may
  /// therefore be reconciled against it before a resumed read.
  ///
  /// True only on the native path. The Dart stream path keeps a LOGICAL device
  /// offset that its ProtocolGapException handler deliberately seeks ahead of the
  /// local bytes (`wal.walOffset = e.incoming`) to resync past a gap — leaving the
  /// bin legitimately shorter than walOffset, with a hole. Rewinding there would
  /// replay the gapped bytes and let the bin reach exactly its advertised length
  /// while still holding a hole, turning a *detected* incomplete transfer into a
  /// *silent* corruption — the very failure this reconciliation exists to prevent.
  bool get _shouldReconcileResume => _reconcileResumeOverride ?? _usesNativeDownload;

  @override
  void cancelSync() {
    if (_isSyncing) {
      _cancelCompleter ??= Completer<void>();
      _isCancelled = true;
      Logger.debug("SDCardWalSync: Cancel requested — stopping immediately");

      // Tell firmware to stop sending (best-effort, fire-and-forget)
      final dev = _device;
      if (dev != null) {
        final connFuture = _connectionProvider != null
            ? _connectionProvider!(dev.id)
            : ServiceManager.instance().device.ensureConnection(dev.id);
        connFuture
            .then((conn) async => await conn?.stopStorageSync() ?? Future.value(false))
            .catchError((_) => Future.value(false));
      }

      // Cancel the BLE stream so the app doesn't hang waiting for an EOT that won't come
      _storageStream?.cancel();
      _storageStream = null;

      // Error the in-flight transfer completer so _readStorageBytesToFile returns immediately
      final transferCompleter = _activeTransferCompleter;
      if (transferCompleter != null && !transferCompleter.isCompleted) {
        transferCompleter.completeError(Exception('Sync cancelled by user'));
      }
    }
  }

  @override
  Future stop() async {
    _wals = [];
    _listedOn = null;
    final dev = _device;
    if (dev != null) {
      final connFuture = _connectionProvider != null
          ? _connectionProvider!(dev.id)
          : ServiceManager.instance().device.ensureConnection(dev.id);
      connFuture
          .then((conn) async => await conn?.stopStorageSync() ?? Future.value(false))
          .catchError((_) => Future.value(false));
    }
    await _storageStream?.cancel();
    _storageStream = null;
    _resetSyncState();
  }

  @override
  Future<void> setDevice(
    BtDevice? device, {
    List<StorageFile>? prefetchedFiles,
  }) async {
    _device = device;
    if (device == null) {
      // Detached — anyone waiting on deviceReady must keep waiting for the next
      // attach rather than seeing a completed future from the last one.
      if (_deviceReady.isCompleted) _deviceReady = Completer<void>();
    }
    if (_device != null) {
      // Restore persisted WAL offsets so partial downloads resume correctly after
      // an app restart, and so fully-downloaded-but-not-yet-deleted files are not
      // re-downloaded from offset 0 (which would create duplicate recordings).
      if (_wals.isEmpty) {
        try {
          final persisted = await WalFileManager.loadWals();
          _wals = persisted.where((w) => w.device == _device!.id).toList();
          _listedOn = null;
          Logger.debug('SDCardWalSync: Loaded ${_wals.length} persisted WALs from disk');
        } catch (e) {
          Logger.debug('SDCardWalSync: Failed to load persisted WALs: $e');
        }
      }

      final connection = _connectionProvider != null
          ? await _connectionProvider!(_device!.id)
          : await ServiceManager.instance().device.ensureConnection(_device!.id);
      if (connection != null) {
        // Skip lock when files are prefetched — _buildWalsFromFilesLocked only
        // needs BLE I/O (listFiles) when prefetchedFiles is null. With files
        // already in hand it needs none at all, so acquiring the lock here would
        // deadlock any caller that already holds it (e.g. refreshStorageStats).
        if (prefetchedFiles == null) {
          await connection.acquireStorageLock('setDevice');
        }
        try {
          // Skip rebuild when prefetchedFiles is an empty list — caller wants to
          // register the device without BLE I/O. An empty file list would make
          // _buildWalsFromFilesLocked return [] and erase the persisted WALs we
          // just loaded. The real rebuild happens when refreshStorageStats() calls
          // setDevice() again with the actual file listing.
          if (prefetchedFiles == null || prefetchedFiles.isNotEmpty) {
            final built = await _buildWalsFromFilesLocked(
              connection,
              _device!.id,
              prefetchedFiles: prefetchedFiles,
            );
            // Same reasoning as the empty-prefetch guard above: a listing that got
            // no answer must not erase the persisted WALs restored a few lines up.
            // Those carry the resume offsets, and dropping them is what makes a
            // half-downloaded bin restart from 0 and duplicate its audio.
            if (built != null) {
              _wals = built.wals;
              _listedOn = built.complete ? built.on : null;
            }
          }
        } finally {
          if (prefetchedFiles == null) {
            connection.releaseStorageLock();
          }
        }
      }
      listener.onWalUpdated();
      // Release waiters LAST. "Ready" has to mean the persisted WAL offsets are
      // restored, not merely that _device is non-null: a waiter freed at the top
      // of this method races the restore above, and a sync that starts without it
      // re-reads a partially-downloaded bin from offset 0 — the duplicate
      // recordings that restore exists to prevent.
      if (!_deviceReady.isCompleted) _deviceReady.complete();
    }
  }

  @override
  Future<Set<String>> incompleteBinRelPaths() async {
    // raw_segments/ is a GLOBAL pool — a bin's path carries no device id — but
    // _wals only ever holds the CONNECTED device's WALs (setDevice filters by
    // w.device, and saveWals deliberately preserves other devices' entries). A
    // second device's half-downloaded bin sits in the same pool and is just as
    // unsafe to decode and prune, so union both sources rather than reading one:
    //  - persisted: every device, and the only source when none is attached
    //    (Force Process / a resume after an app restart still has to honour a
    //    half-downloaded bin left behind by an earlier session).
    //  - _wals: fresher for the current device — its offsets run ahead of the
    //    ~1 Hz-throttled persist — so it wins on conflict.
    //
    // Key by relativeBinPath, the PHYSICAL identity processing matches on — NOT
    // Wal.id (`$device-$timerStart`). A pre-time-sync bin carries its sessionId in
    // the path (session_<sid>/…), so two such bins with the same low timerStart but
    // different sessionIds share a Wal.id yet are distinct files; keying by Wal.id
    // would collapse them and expose one partial to pruning. Same-path entries ARE
    // the same physical bin, so live-over-persisted precedence still holds.
    final byPath = <String, Wal>{};
    // Do NOT swallow a load failure. _loadWalsUnlocked returns [] for missing/
    // empty/bad-format, so a throw here means a genuinely unreadable or half-written
    // wals.json — exactly when other devices' (and, with no device attached, this
    // device's) partial bins live ONLY in that file. Failing open would drop them
    // from the protection set and let processing prune a mid-download bin, re-opening
    // the corruption this whole change prevents. Propagate so the caller fails closed
    // (skips the pruning pass) until the next sync rewrites a clean wals.json.
    for (final w in await WalFileManager.loadWals()) {
      byPath[w.relativeBinPath] = w;
    }
    for (final w in _wals) {
      byPath[w.relativeBinPath] = w;
    }
    return byPath.values
        .where((w) {
          // A pending legacy native prefix can contain padding even at full length.
          // Protect it before a download reaches the migration gate: processing also
          // runs after a failed listing, or with only persisted WALs and no device.
          final needsMigration = _usesNativeDownload &&
              w.storage == WalStorage.sdcard &&
              w.status != WalStatus.synced &&
              w.nativeIntegrityVersion != 1;
          return w.isIncompleteTransfer || needsMigration;
        })
        .map((w) => w.relativeBinPath)
        .toSet();
  }

  /// What the new pipeline's planner needs from the sync: the files the Omi lists that
  /// are not all here yet ([listed]), those of them with nothing on the phone (holes,
  /// [missing]), and those given up on ([waived]: see [givenUpOn]). From the last listing,
  /// or the persisted one before any this process. [listedOn] is when and on which link
  /// the sync took that listing complete ([_listedOn]), or null.
  Future<
      ({
        List<RawFileKey> missing,
        Set<RawFileKey> waived,
        Set<RawFileKey> listed,
        ({int atMs, int link, int linkSinceMs})? listedOn
      })> rawFileState() async {
    final deviceId = _device?.id ?? SharedPreferencesUtil().btDevice.id;
    final listedOn = _listedOn;
    // A copy: the loop below waits, and a sync may change the list meanwhile.
    final wals = List.of(_wals.isNotEmpty || listedOn != null ? _wals : await WalFileManager.loadWals());
    final store = await _rawStore();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final missing = <RawFileKey>[];
    final waived = <RawFileKey>{};
    final listed = <RawFileKey>{};
    for (final w in wals) {
      if (w.device != deviceId || w.storage != WalStorage.sdcard || w.status == WalStatus.synced) continue;
      final key = _keyOf(w);
      listed.add(key);
      if (givenUpOn(w, nowMs)) {
        waived.add(key);
      } else if ((await store.load(key)).chunks.isEmpty) {
        missing.add(key);
      }
    }
    return (missing: missing, waived: waived, listed: listed, listedOn: listedOn);
  }

  @override
  Future<Set<String>> heldBackBinRelPaths() async {
    final deviceId = _device?.id ?? SharedPreferencesUtil().btDevice.id;
    if (deviceId.isEmpty) return const {};
    // Persisted first, live over it, as in incompleteBinRelPaths — and failing closed the
    // same way: a throw from loadWals is a wals.json that could not be read.
    final byPath = <String, Wal>{};
    for (final w in await WalFileManager.loadWals()) {
      if (w.device == deviceId) byPath[w.relativeBinPath] = w;
    }
    for (final w in _wals) {
      if (w.device == deviceId) byPath[w.relativeBinPath] = w;
    }
    // The oldest file of each boot still waiting on the device. Within one boot the
    // firmware keeps every new file's timestamp later than the last (uptime-keyed files
    // before UTC-keyed ones), so "older" is a plain comparison inside the session. A WAL
    // without a session id is the session its own bin is filed under, 0.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final oldestWaiting = <int, int>{};
    for (final w in byPath.values) {
      if (w.storage != WalStorage.sdcard || w.status == WalStatus.synced) continue;
      if (givenUpOn(w, nowMs)) continue;
      final session = w.sessionId ?? 0;
      final current = oldestWaiting[session];
      if (current == null || w.timerStart < current) oldestWaiting[session] = w.timerStart;
    }
    if (oldestWaiting.isEmpty) return const {};

    final rawDir = Directory('${(await getApplicationDocumentsDirectory()).path}/raw_segments');
    if (!await rawDir.exists()) return const {};
    final held = <String>{};
    await for (final folder in rawDir.list()) {
      if (folder is! Directory) continue;
      final folderName = folder.path.replaceAll('\\', '/').split('/').last;
      await for (final bin in folder.list()) {
        if (bin is! File || !bin.path.endsWith('.bin')) continue;
        final name = bin.path.replaceAll('\\', '/').split('/').last;
        final parts = name.substring(0, name.length - 4).split('_');
        if (parts.length != 2) continue;
        final timerStart = int.tryParse(parts[0]);
        final session = int.tryParse(parts[1]);
        if (timerStart == null || session == null) continue;
        final oldest = oldestWaiting[session];
        if (oldest != null && timerStart > oldest) held.add('$folderName/$name');
      }
    }
    if (held.isNotEmpty) {
      Logger.debug('SDCardWalSync: holding ${held.length} bin(s) back from processing until an older file of '
          'their boot arrives from the device');
    }
    return held;
  }

  @override
  ({bool unknownTime, int? utcSeconds}) get oldestFileWaitingOnDevice {
    int? oldest;
    for (final w in _wals) {
      if (w.storage != WalStorage.sdcard || w.status == WalStatus.synced) continue;
      if (w.timerStart < 946684800) return (unknownTime: true, utcSeconds: null);
      if (oldest == null || w.timerStart < oldest) oldest = w.timerStart;
    }
    return (unknownTime: false, utcSeconds: oldest);
  }

  @override
  Future<List<Wal>> getMissingWals() async {
    final dev = _device;
    if (dev == null) return [];

    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return [];

    await connection.acquireStorageLock('getMissingWals');
    try {
      // Public contract stays non-null: this is the informational view (start(),
      // the UI's WAL list), where "no answer" and "nothing there" are equally
      // uninformative. Only the sync path branches on the difference.
      return (await _getMissingWalsLocked(connection, dev.id))?.wals ?? [];
    } finally {
      connection.releaseStorageLock();
    }
  }

  /// null = the device never answered the listing. See [_buildWalsFromFilesLocked].
  Future<({List<Wal> wals, bool complete, ({int atMs, int link, int linkSinceMs})? on})?> _getMissingWalsLocked(
      DeviceConnection connection, String deviceId) async {
    final built = await _buildWalsFromFilesLocked(connection, deviceId);
    Logger.debug('SDCardWalSync: getMissingWals returned '
        '${built == null ? 'NO ANSWER (listing failed)' : '${built.wals.length} WALs'
            '${built.complete ? '' : ' (listing incomplete — more files remain)'}'}');
    return built;
  }

  /// Re-issues CMD_DELETE_FILE for every WAL this device still lists that we already
  /// received in full, and reports whether the device's queue head is now a file the
  /// fast path may read.
  ///
  /// A `synced` WAL survives a listing rebuild only when the device still advertises the
  /// file (_buildWalsFromFilesLocked builds exclusively from the listing, and a successful
  /// delete drops the entry), so its presence here means exactly one thing: an earlier
  /// delete did not take. Nothing else would ever ask the device to drop those files —
  /// the download loop skips them by status — so without this sweep they stay on the card
  /// forever, and every sync re-reports the same stale file count.
  ///
  /// Re-deleting is safe and idempotent: the app sends the file's timestamp alongside the
  /// index, and the firmware answers success for a segment that is already gone.
  ///
  /// Each delete is addressed at the file's current index ([_currentIndex]) and recorded
  /// in [deletedListIndices], so the downloads that follow address theirs correctly too.
  ///
  /// `allDeleted` is false while any of them is still on the device: the card is not
  /// drained, so the cycle is partial. `uncertain` is true when a delete failed: one whose
  /// reply was lost may still have taken, which moves every later file down a place, so
  /// the indices no longer say where the files are. No further delete is sent then —
  /// on firmware that deletes by index alone, the next would land on the file after the
  /// one meant, which may not have downloaded — and the caller lists again.
  Future<({bool allDeleted, bool uncertain})> _retryPendingDeletesLocked(
      DeviceConnection connection, String deviceId, List<int> deletedListIndices) async {
    final pending = _wals.where((w) => w.storage == WalStorage.sdcard && w.status == WalStatus.synced).toList()
      ..sort((a, b) => a.fileNum.compareTo(b.fileNum));
    if (pending.isEmpty) return (allDeleted: true, uncertain: false);

    Logger.warning('SDCardWalSync: ${pending.length} file(s) already received in full are still on the device '
        '(a previous delete did not take) — retrying their deletion before syncing');

    bool allDeleted = true;
    bool anyDeleted = false;
    bool uncertain = false;
    for (final wal in pending) {
      if (_isCancelled || !await connection.isConnected()) {
        allDeleted = false;
        break;
      }
      try {
        await _deleteWalLocked(connection, wal,
            overrideFileNum: _currentIndex(wal, deletedListIndices), skipSave: true);
        deletedListIndices.add(wal.fileNum);
        anyDeleted = true;
        // Settle delay: give the SD worker time to finish its metadata update before the
        // next storage command, matching the download loop's post-delete pause.
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        Logger.error('SDCardWalSync: delete retry still failing for ts=${wal.timerStart}: $e — no more deletes '
            'until the files are listed again');
        allDeleted = false;
        uncertain = true;
        break;
      }
    }
    if (anyDeleted) {
      await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
    }
    return (allDeleted: allDeleted, uncertain: uncertain);
  }

  /// Where [wal] sits in the device's file list now: its index in this session's
  /// listing, less the files deleted ahead of it since ([deletedListIndices], listing
  /// indices). A delete shifts every later file down a place, and nothing else moves an
  /// earlier one — new recordings join at the end — so this is exact; the timestamp
  /// sent with it stays the firmware's check. Reading the oldest file at index 0 was
  /// only right while every file before it had been deleted.
  static int _currentIndex(Wal wal, List<int> deletedListIndices) =>
      wal.fileNum - deletedListIndices.where((d) => d < wal.fileNum).length;

  /// One attempt at [wal] that did not finish it, for a reason of the file's own.
  /// [madeProgress] = bytes beyond where this attempt resumed (a realigned resume sits
  /// before the gap it retries, so a gap hit again counts as none). The first such
  /// attempt starts the file's [Wal.failingSinceMs] clock, which progress does not reset.
  static void _countFailedAttempt(Wal wal, {required bool madeProgress}) {
    wal.syncFailCount = madeProgress ? 0 : wal.syncFailCount + 1;
    wal.failingSinceMs ??= DateTime.now().millisecondsSinceEpoch;
  }

  /// The storage reading the current sync took, if any. See [_syncAllLocked].
  StorageFileStats? _lastStorageStats;

  /// How much more the Omi can record, in minutes, before it overwrites audio not yet
  /// synced; -1 when [stats] cannot say. Only the ring backend (1) overwrites — keep-
  /// newest, from the oldest end — and its free space is exactly the room before it
  /// does: synced audio behind an older unsynced file is not reusable until that file
  /// goes. Opus on the card averages about 4 050 B/s while recording.
  static int overwriteMinutesLeft(StorageFileStats? stats) {
    if (stats == null || stats.storageBackend != 1) return -1;
    return stats.freeBytes ~/ (4050 * 60);
  }

  Future<void> _updateStorageStatsLocked(DeviceConnection connection) async {
    try {
      final stats = await connection.getStorageFileStats();
      if (stats != null) {
        _lastStorageStats = stats;
        listener.onStorageStatsUpdated(stats);
      }
    } catch (e) {
      Logger.debug('SDCardWalSync: Failed to update storage stats: $e');
    }
  }

  @override
  Future<bool> hasFilesToSync() async {
    if (_device == null) return false;
    if (_wals.isNotEmpty) return true;

    final connection = _connectionProvider != null
        ? await _connectionProvider!(_device!.id)
        : await ServiceManager.instance().device.ensureConnection(_device!.id);
    if (connection == null) return false;

    await connection.acquireStorageLock('hasFilesToSync');
    try {
      // No answer is not evidence of files, and this is a bool with no third state.
      final listing = await connection.listFiles();
      return listing != null && listing.files.isNotEmpty;
    } finally {
      connection.releaseStorageLock();
    }
  }

  /// Returns null when the device never answered the listing — distinct from an
  /// empty list, which is the device answering that it holds nothing. Callers that
  /// decide whether a sync RAN must branch on it; see [DeviceConnection.listFiles].
  ///
  /// `complete` carries [StorageListing.complete] through: false means the device
  /// named more files than it delivered, so the WALs built here are a prefix of
  /// the card and the run that syncs them is a partial sync.
  ///
  /// `on` is when and on which link this listing was taken ([_listedOn]): null for
  /// prefetched files, and for a listing during which the link changed.
  Future<({List<Wal> wals, bool complete, ({int atMs, int link, int linkSinceMs})? on})?> _buildWalsFromFilesLocked(
    DeviceConnection connection,
    String deviceId, {
    List<StorageFile>? prefetchedFiles,
  }) async {
    // The prefetch path is used only by setDevice, which reads `.wals` and never
    // this flag — so `true` here is not a claim about the caller's listing, which
    // refreshStorageStats in fact discards the completeness of. (Its `on` is null, so
    // the pipeline concludes nothing from it.) If a future caller
    // ever routes prefetched files into a SYNC, thread the real StorageListing
    // through instead of trusting this: a short listing reported complete is
    // exactly the wrong answer the rest of this change exists to prevent.
    final link = connection.link;
    final linkSinceMs = connection.linkSinceMs;
    final atMs = DateTime.now().millisecondsSinceEpoch;
    final listing = prefetchedFiles != null ? (files: prefetchedFiles, complete: true) : await connection.listFiles();
    if (listing == null) return null;
    ({int atMs, int link, int linkSinceMs})? on;
    if (prefetchedFiles == null) {
      if (connection.link == link) {
        on = (atMs: atMs, link: link, linkSinceMs: linkSinceMs);
      } else {
        Logger.debug('SDCardWalSync: the link changed during the listing; it says nothing of ended sessions');
      }
    }
    final files = listing.files;
    if (files.isEmpty) return (wals: <Wal>[], complete: listing.complete, on: on);

    final wals = <Wal>[];

    const int kMaxStorageBytes = 0x1E000000;

    for (final file in files) {
      if (file.size > kMaxStorageBytes) {
        Logger.error(
          'SDCardWalSync: file[${file.index}] has impossible size ${file.size} (> 480 MB)',
        );
        continue;
      }

      // Indices shift after deletion. Match the exact segment identity instead:
      // one boot session can contain many distinct pre-UTC timestamps. Reusing
      // another segment's integrity version would certify an unmigrated prefix.
      final existing = _wals.firstWhereOrNull(
        (w) =>
            w.device == deviceId &&
            w.timerStart == file.timestamp &&
            w.sessionId == file.sessionId &&
            w.storage == WalStorage.sdcard,
      );
      final isMatchValid = existing != null;

      final walOffset =
          (isMatchValid && existing.walOffset > 0 && existing.walOffset <= file.size) ? existing.walOffset : 0;

      // A file we already received IN FULL that the device is STILL listing is one whose
      // CMD_DELETE_FILE did not take (rejected, timed out, or the ACK was lost). Carry the
      // `synced` status across the re-list so the download loop skips it and only the
      // delete is retried.
      //
      // Without this the rebuilt WAL defaults to `miss` and the file is downloaded again —
      // and by now the processing pass has usually consumed and pruned the local bin, so
      // the "resume" finds nothing on disk, _reconcileResumeOffset rewinds to 0, and the
      // whole file is re-fetched and decoded a SECOND time. That is duplicate audio, and
      // carrying walOffset alone does not prevent it (the rewind discards it).
      //
      // Only safe while the device advertises no more bytes than we already hold: a file
      // that GREW has audio we never received and must resume — and must not be deleted —
      // so it stays `miss`. walOffset is 0 unless it carried over, so the `> 0` term also
      // leaves a 0-byte file as `miss`; re-reading one is free and duplicates nothing.
      final bool alreadyComplete =
          isMatchValid && existing.status == WalStatus.synced && walOffset > 0 && file.size <= walOffset;

      // Trust the raw firmware timestamp. Never "invent" a UTC time here;
      // pre-sync files stay low (e.g. 1010) so the protocol remains honest.
      final timerStart = file.timestamp;

      final wal = Wal(
        device: deviceId,
        fileNum: file.index,
        walOffset: walOffset,
        storageTotalBytes: file.size,
        timerStart: timerStart,
        sessionId: file.sessionId,
        storage: WalStorage.sdcard,
        status: alreadyComplete ? WalStatus.synced : WalStatus.miss,
      );
      if (isMatchValid && existing.isSyncing) {
        wal.isSyncing = true;
        wal.syncStartedAt = existing.syncStartedAt;
      }
      // Carry the failure count and clock across list refreshes, so a file that keeps
      // failing is still known as one (retry order, and how long processing has waited
      // for it). Only meaningful when the identity actually matches.
      if (isMatchValid) {
        wal.syncFailCount = existing.syncFailCount;
        wal.failingSinceMs = existing.failingSinceMs;
        wal.nativeIntegrityVersion = existing.nativeIntegrityVersion;
        wal.lastIntegrityGapOffset = existing.lastIntegrityGapOffset;
      }
      wals.add(wal);
    }
    return (wals: wals, complete: listing.complete, on: on);
  }

  @override
  Future deleteWal(Wal wal) async {
    final dev = _device;
    if (dev == null) return;
    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return;

    await connection.acquireStorageLock('deleteWal');
    try {
      await _deleteWalLocked(connection, wal);
    } finally {
      connection.releaseStorageLock();
    }
  }

  Future _deleteWalLocked(DeviceConnection connection, Wal wal, {int? overrideFileNum, bool skipSave = false}) async {
    final targetIdx = overrideFileNum ?? wal.fileNum;
    Logger.debug('SDCardWalSync: deleting synced WAL from SD card: index=$targetIdx ts=${wal.timerStart}');
    final connected = await connection.isConnected();
    if (!connected) throw Exception('Device disconnected before deletion of index=$targetIdx ts=${wal.timerStart}');
    final success = await connection.deleteFile(
      StorageFile(index: targetIdx, timestamp: wal.timerStart, size: 0),
    );
    if (!success) throw Exception('Firmware rejected deletion of index=$targetIdx ts=${wal.timerStart}');
    // Drop the WAL by PHYSICAL identity, not Wal.id. Wal.id is `$device-$timerStart`,
    // and pre-time-sync segments key timerStart on uptime seconds, which restart at 0
    // every boot — so two bins recorded before the clock was ever set, in different
    // boots, can share an id while being different files (they differ by sessionId,
    // which is why _buildWalsFromFilesLocked also matches sessionId and
    // incompleteBinRelPaths keys on relativeBinPath). Removing by id here evicts the
    // colliding sibling too, losing its resume offset and strike count: it is rebuilt
    // as `miss` at offset 0 and re-downloaded in full. relativeBinPath carries the
    // sessionId, so it separates them. _wals holds one device, but match on device
    // anyway — the path alone carries no device id.
    _wals.removeWhere((w) => w.device == wal.device && w.relativeBinPath == wal.relativeBinPath);
    listener.onWalUpdated();
    // Persist after deletion so the WAL is gone from disk even if the app restarts before
    // the next natural save point. This prevents re-downloading a deleted file.
    if (!skipSave) {
      WalFileManager.saveWals(_wals, deviceId: wal.device).catchError((_) => Future.value(false));
    }
  }

  Future<(File, int)> _flushToDisk(
    Wal wal,
    List<int> rawData,
    int timerStart, {
    required String subFolder,
    bool append = false,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final folderPath = '${directory.path}/raw_segments/$subFolder';

    final folder = Directory(folderPath);
    if (!await folder.exists()) await folder.create(recursive: true);

    final fileName = '${timerStart}_${wal.sessionId ?? 0}.bin';

    String filePath = '${folder.path}/$fileName';
    final file = File(filePath);
    await file.writeAsBytes(
      rawData,
      mode: append ? FileMode.append : FileMode.write,
    );

    if (SharedPreferencesUtil().adjustmentMode) {
      try {
        final adjFolder = Directory('${directory.path}/adjustment_mode_segments/$subFolder');
        if (!await adjFolder.exists()) await adjFolder.create(recursive: true);
        await file.copy('${adjFolder.path}/$fileName');
      } catch (e) {
        Logger.error('SDCardWalSync: failed to copy bin to adjustment_mode_segments: $e');
      }
    }

    return (file, rawData.length);
  }

  /// Reconciles a resume [offset] against what is actually in [binFile], and
  /// returns the offset the device should be asked to resume from. The device's
  /// copy is immutable until CMD_DELETE_FILE, so re-fetching either way is safe.
  ///
  /// NATIVE PATH ONLY. Here walOffset is always "bytes in the local bin" (the
  /// caller sets it from the on-disk size), so any divergence is a fault to
  /// repair. The Dart stream path keeps a *logical* device offset that its
  /// gap handler seeks ahead on purpose — see the truncate block there.
  ///
  /// walOffset and the local bin can diverge in BOTH directions:
  ///  - Bin LONGER than the offset: a prior session was killed between a flush
  ///    (which put bytes on disk) and the next ~1 Hz-throttled walOffset persist.
  ///    Those bytes are about to be re-fetched, so truncate — keeping them would
  ///    duplicate audio mid-bin and desync the VAD frame parser.
  ///  - Bin SHORTER, or gone: the processing pass consumed a partial bin into a
  ///    draft and pruned it (it deletes every bin it decodes). Resuming at the
  ///    stale offset asks the device for the TAIL and lands it at position 0 of a
  ///    recreated file — downloadStorageFile opens the path with append=true,
  ///    which silently creates an empty file when it is missing.
  ///
  ///    The result is not a transient glitch that self-heals; it converges on
  ///    silent corruption in exactly two syncs. With `T` = advertised size and
  ///    `a` = bytes on disk when the bin was pruned:
  ///      sync 1: asks from `a`, receives `T - a` into the recreated file → the
  ///              offset REGRESSES to `T - a` (logged as "no progress", +1 strike)
  ///      sync 2: asks from `T - a`, receives `a`, appends → length is now
  ///              `(T - a) + a` == `T`, EXACTLY the advertised size, always.
  ///    So it always passes the length-only completeness guard, and the device
  ///    copy — the last intact source — is deleted. The bin holds the tail twice
  ///    and has lost its first `T - a` bytes. Observed with T=2071116/a=1338480.
  ///
  ///    Rewind to what is really on disk instead, so every read is contiguous.
  Future<int> _reconcileResumeOffset(File binFile, int offset, Wal wal) async {
    try {
      final bool exists = await binFile.exists();
      final int actualSize = exists ? await binFile.length() : 0;
      if (actualSize == offset) return offset;

      if (actualSize > offset) {
        final raf = await binFile.open(mode: FileMode.append);
        try {
          await raf.truncate(offset);
        } finally {
          await raf.close();
        }
        Logger.debug(
            'SDCardWalSync: Truncated ${binFile.path} from $actualSize to $offset bytes (resume reconciliation)');
        return offset;
      }

      Logger.error('SDCardWalSync: ts=${wal.timerStart} resume offset $offset is past the $actualSize B '
          'actually on disk (bin ${exists ? 'truncated' : 'missing'}) — rewinding to $actualSize so the '
          'resumed read cannot append the tail onto a gap');
      wal.walOffset = actualSize;
      return actualSize;
    } catch (e) {
      // The file's state is now UNKNOWN — exists()/length()/truncate() failed. Do
      // not hand the stale offset back: if the bin is missing or short, the
      // caller appends the tail onto a gap and recreates the exact corruption
      // this helper exists to stop. Fail to a full re-fetch instead. The device
      // copy is immutable until CMD_DELETE_FILE, and offset 0 makes the native
      // writer truncate rather than append, so this costs bandwidth and nothing
      // else — the one safe answer when we cannot see the file.
      Logger.error('SDCardWalSync: resume reconciliation failed for ${binFile.path} — '
          'restarting this bin from 0 (cannot trust offset $offset): $e');
      wal.walOffset = 0;
      return 0;
    }
  }

  /// Absolute path of [wal]'s bin in the processing pool.
  Future<File> _binFileFor(Wal wal) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/raw_segments/${wal.relativeBinPath}');
  }

  /// Rewinds [wal].walOffset to the bytes actually on disk, BEFORE a caller
  /// snapshots it for progress / disk-space bookkeeping.
  ///
  /// _reconcileResumeOffset also runs inside the native read, but by then
  /// _syncAllLocked has already captured `initialOffset` from the stale value —
  /// and it treats that as "this attempt's resume point" when deciding whether a
  /// read made forward progress. A rewind would leave a phantom baseline: a
  /// resumed read that genuinely advanced (say 0 → 500 KB after a rewind from
  /// 1.3 MB) would score as "no progress", burn a strike, and at 5 strikes the
  /// poison-drop deletes the recording outright — the precise data loss the
  /// forward-progress guard was added to prevent. Reconciling first keeps the
  /// snapshot honest, and also sizes the disk-space reservation for what will
  /// really be fetched. No-op when nothing was downloaded yet.
  Future<void> _reconcileWalOffsetToDisk(Wal wal) async {
    // Sealed chunks are never cut: _applySealedState set the resume point.
    if (RawChunkStore.enabled) return;
    if (_usesNativeDownload && wal.nativeIntegrityVersion != 1) {
      // A legacy pending prefix can have the right length and still contain holes.
      // Re-fetch it once. The version is set only AFTER truncation in the reader.
      wal.walOffset = 0;
      return;
    }
    if (!_shouldReconcileResume) return; // stream path: walOffset is a logical offset
    if (wal.walOffset <= 0) return;
    try {
      await _reconcileResumeOffset(await _binFileFor(wal), wal.walOffset, wal);
    } catch (e) {
      Logger.error('SDCardWalSync: could not reconcile the resume offset for ts=${wal.timerStart}: $e');
    }
  }

  Future _readStorageBytesToFileLocked(
    DeviceConnection connection,
    Wal wal,
    Function(File f, int offset, int timerStart, {String? subFolder}) callback, {
    Function(int offset)? onProgress,
    int? overrideFileNum,
  }) async {
    // Native whole-file download (writes straight to disk, no per-packet Dart hop).
    // Android and iOS both implement BleHostApi.downloadStorageFile; other platforms
    // fall through to the Dart notification-stream path below.
    if (_usesNativeDownload) {
      return await _readStorageBytesToFileLockedNative(connection, wal, callback,
          onProgress: onProgress, overrideFileNum: overrideFileNum);
    }
    int fileNum = overrideFileNum ?? wal.fileNum;
    int offset = wal.walOffset;
    int timerStart = wal.timerStart;

    if (_isCancelled) throw Exception("Cancelled");

    final completer = Completer<void>();
    _activeTransferCompleter = completer;
    bool hasError = false;
    bool isProcessing = false;
    bool eotReceived = false;

    final Queue<Uint8List> chunkQueue = Queue<Uint8List>();
    final BytesBuilder batchBuilder = BytesBuilder(copy: false);
    final Set<String> flushedSegmentsThisTransfer = {};
    int writtenOffset = offset;

    // Use 'session_$sessionId' prefix for pre-sync timestamps so they land in the 'Unorganized' UI section
    String subFolderPrefix = (timerStart < 946684800) ? 'session_${wal.sessionId}' : timerStart.toString();

    if (offset > 0) {
      final directory = await getApplicationDocumentsDirectory();
      final existingFile = File(
        '${directory.path}/raw_segments/$subFolderPrefix/${timerStart}_${wal.sessionId ?? 0}.bin',
      );
      if (await existingFile.exists()) {
        // Truncate-on-resume: file.length and wal.walOffset can diverge if a
        // prior session was killed between writeAsBytes (which flushed bytes to
        // disk) and the next walOffset persist (every ~2 MB / per-flush). Any
        // bytes on disk beyond walOffset are about to be re-fetched from the
        // device — keeping them would duplicate audio in the middle of the bin
        // and confuse the VAD frame parser. The device's stored file is
        // immutable until we send CMD_DELETE_FILE, so the re-fetch is safe.
        //
        // Only the file-is-LONGER direction is reconciled here. Unlike the
        // native path, walOffset on this path is a LOGICAL device offset that
        // the ProtocolGapException handler deliberately seeks ahead of the local
        // bytes (`wal.walOffset = e.incoming`) to resync past a gap, so a bin
        // shorter than walOffset is expected here and must not be rewound.
        try {
          final actualSize = await existingFile.length();
          if (actualSize > offset) {
            final raf = await existingFile.open(mode: FileMode.append);
            try {
              await raf.truncate(offset);
            } finally {
              await raf.close();
            }
            Logger.debug(
                'SDCardWalSync: Truncated ${existingFile.path} from $actualSize to $offset bytes (resume reconciliation)');
          }
        } catch (e) {
          Logger.error('SDCardWalSync: truncate-on-resume failed for ${existingFile.path}: $e');
        }
        flushedSegmentsThisTransfer.add('${timerStart}_${wal.sessionId ?? 0}');
      }
    }

    Future<void> flushRawBuffer(List<int> rawData) async {
      if (rawData.isEmpty) return;
      final segmentKey = '${timerStart}_${wal.sessionId ?? 0}';
      final appendMode = flushedSegmentsThisTransfer.contains(segmentKey);
      if (!appendMode) flushedSegmentsThisTransfer.add(segmentKey);

      var (file, bytesWritten) = await _flushToDisk(
        wal,
        rawData,
        timerStart,
        subFolder: subFolderPrefix,
        append: appendMode,
      );
      writtenOffset += bytesWritten;
      _lastSegmentBoundaryOffset = writtenOffset;
      try {
        await callback(file, writtenOffset, timerStart, subFolder: subFolderPrefix);
      } catch (_) {}
    }

    _storageStream?.cancel();
    int expectedOffset = offset;
    _lastSegmentBoundaryOffset = offset;
    bool hasReceivedStartAck = false;
    bool isStreamLocked = false;
    int packetsReceived = 0;
    Timer? inactivityTimer;

    void resetInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(_inactivityTimeout, () {
        if (!completer.isCompleted) {
          isStreamLocked = true;
          hasError = true;
          completer.completeError(
            Exception("Transfer stalled: ${_inactivityTimeout.inSeconds}s inactivity timeout"),
          );
        }
      });
    }

    resetInactivityTimer();

    _storageStream = (await connection.getBleStorageBytesStream()).listen(
      (List<int> value) async {
        resetInactivityTimer();
        if (_isCancelled || hasError || isStreamLocked) return;
        packetsReceived++;
        if (packetsReceived % 500 == 0) {
          Logger.debug(
            'SDCardWalSync: [PROGRESS] received $packetsReceived packets, offset=$expectedOffset bytes',
          );
        }
        if (value.isEmpty) return;

        int packetType = value[0];
        switch (packetType) {
          case 0x01:
            if (!hasReceivedStartAck || value.length < 5) return;
            int incomingOffset = value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24);
            List<int> payload = value.sublist(5);

            if (incomingOffset < expectedOffset) {
              final packetEnd = incomingOffset + payload.length;
              if (packetEnd <= expectedOffset) return;
              payload = payload.sublist(expectedOffset - incomingOffset);
            } else if (incomingOffset > expectedOffset) {
              isStreamLocked = true;
              hasError = true;
              if (!completer.isCompleted) {
                completer.completeError(
                  ProtocolGapException(incomingOffset, expectedOffset),
                );
              }
              return;
            }

            chunkQueue.add(Uint8List.fromList(payload));
            expectedOffset += payload.length;
            if (onProgress != null) onProgress(expectedOffset);
            break;

          case 0x02:
            // Same gate as DATA, and as the native path (OmiBleManager.kt): the firmware
            // ACKs a read before streaming, so an EOT ahead of the ACK is an earlier
            // transfer's tail and must not complete this one with nothing written.
            if (!hasReceivedStartAck) return;
            isStreamLocked = true;
            eotReceived = true;
            if (!isProcessing) {
              if (chunkQueue.isNotEmpty) {
                while (chunkQueue.isNotEmpty) {
                  batchBuilder.add(chunkQueue.removeFirst());
                }
                await flushRawBuffer(batchBuilder.takeBytes());
              }
              _lastSegmentBoundaryOffset = writtenOffset;
              if (!completer.isCompleted) completer.complete();
            }
            return;

          case 0x03:
            if (value.length < 2) return;
            // oo-3.1.5+ names the command in every other ACK ([0x03][result][cmd]); one naming
            // anything but CMD_READ_FILE belongs to another command and says nothing about
            // this read. Same rule as OmiBleManager's native path.
            if (value.length == 3 && value[2] != 0x11) return;
            // oo-3.1.4+ echoes the requested timestamp ([0x03][result][ts:4 LE]); one that
            // names another file is a late ACK for an earlier read and must not open this
            // download to that file's stream. Same rule as OmiBleManager's native path.
            if (value.length >= 6 && timerStart != 0) {
              final echoed = value[2] | (value[3] << 8) | (value[4] << 16) | (value[5] << 24);
              if (echoed != 0 && echoed != timerStart) return;
            }
            if (value[1] == 0x00) {
              hasReceivedStartAck = true;
            } else {
              isStreamLocked = true;
              hasError = true;
              if (!completer.isCompleted) {
                completer.completeError(AckException(value[1]));
              }
              return;
            }
            break;
        }

        if (isProcessing) return;
        isProcessing = true;
        try {
          const int batchSizeLimit = 4096;

          while (chunkQueue.isNotEmpty) {
            int batchSize = 0;

            // Build batch WITHOUT await
            while (chunkQueue.isNotEmpty && batchSize < batchSizeLimit) {
              final chunk = chunkQueue.removeFirst();
              batchBuilder.add(chunk);
              batchSize += chunk.length;
            }

            final Uint8List batch = batchBuilder.takeBytes();

            // ---- SAFE FLUSH ----
            await flushRawBuffer(batch);
          }
        } finally {
          isProcessing = false;
          if (eotReceived && !completer.isCompleted) {
            completer.complete();
          }
        }
      },
      onError: (e) {
        hasError = true;
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          if (eotReceived) {
            completer.complete();
          } else {
            completer.completeError(Exception('Stream closed without EOT'));
          }
        }
      },
    );

    try {
      final readStarted = await connection.writeToStorage(
        fileNum,
        0x11,
        offset,
        timestamp: timerStart,
      );
      if (!readStarted) throw Exception('Could not start SD card read');
      await completer.future;
    } finally {
      inactivityTimer?.cancel();
      // Ensure the firmware closes its read handle before we return (and potentially
      // try to delete the file). CMD_STOP_SYNC (0x03) forces this on the firmware.
      await connection.stopStorageSync();

      // Cancel the stream subscription so it doesn't receive the next operation's
      // ACK packets (e.g. DELETE ACK) and misinterpret them as a new read start-ACK.
      await _storageStream?.cancel();
      _storageStream = null;
    }
  }

  // Android-only: receives BLE packets natively (binder thread → file), polls
  // the output file size at 1 Hz for WAL offset tracking, and calls [callback]
  // once on completion. iOS uses the existing stream path above.
  Future _readStorageBytesToFileLockedNative(
    DeviceConnection connection,
    Wal wal,
    Function(File f, int offset, int timerStart, {String? subFolder}) callback, {
    Function(int offset)? onProgress,
    int? overrideFileNum,
  }) async {
    if (RawChunkStore.enabled) {
      return _readSealedLocked(connection, wal, callback, onProgress: onProgress, overrideFileNum: overrideFileNum);
    }
    final fileNum = overrideFileNum ?? wal.fileNum;
    int offset = wal.walOffset;
    final timerStart = wal.timerStart;

    if (_isCancelled) throw Exception("Cancelled");

    final String subFolderPrefix = (timerStart < 946684800) ? 'session_${wal.sessionId}' : timerStart.toString();

    final directory = await getApplicationDocumentsDirectory();
    final folderPath = '${directory.path}/raw_segments/$subFolderPrefix';
    await Directory(folderPath).create(recursive: true);
    final outputPath = '$folderPath/${timerStart}_${wal.sessionId ?? 0}.bin';
    final outputFile = File(outputPath);

    if (wal.nativeIntegrityVersion != 1) {
      await outputFile.writeAsBytes(const <int>[], flush: true);
      offset = 0;
      wal.walOffset = 0;
      wal.nativeIntegrityVersion = 1;
    }

    // Truncate-on-resume: same guard as the stream path.
    if (offset > 0) {
      offset = await _reconcileResumeOffset(outputFile, offset, wal);
    }

    // _activeTransferCompleter is not used for the native path; cancellation is
    // handled by _isCancelled + poll timer calling stopStorageSync → firmware
    // stops sending → native inactivity timeout fires → downloadStorageFile throws.
    _activeTransferCompleter = null;

    final hostApi = BleHostApi();
    Timer? pollTimer;
    int lastPolledSize = offset;
    bool integrityFailed = false;

    pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isCancelled) {
        pollTimer?.cancel();
        connection.stopStorageSync().catchError((_) => false);
        return;
      }
      try {
        final currentSize = outputFile.existsSync() ? outputFile.lengthSync() : lastPolledSize;
        if (currentSize > lastPolledSize) {
          lastPolledSize = currentSize;
          _lastSegmentBoundaryOffset = currentSize;
          onProgress?.call(currentSize);
        }
      } catch (_) {}
    });

    _activeDownloadPath = outputPath;
    _stopFailedAfterIntegrityGap = false;
    _integrityGapRepeated = false;
    try {
      await hostApi.downloadStorageFile(
        _device!.id,
        fileNum,
        offset,
        timerStart,
        outputPath,
      );
    } on PlatformException catch (e) {
      if (_isStorageIntegrityError(e)) {
        integrityFailed = true;
        // Native has closed the writer. Its accepted offset also excludes a
        // partially failed write; polling/physical length alone cannot do that.
        final details = e.details;
        final expected = details is Map ? details['expectedOffset'] : null;
        final incoming = details is Map ? details['incomingOffset'] : null;
        int safeOffset = 0;
        try {
          final size = await outputFile.length();
          if (expected is int && expected >= 0) safeOffset = expected < size ? expected : size;
        } catch (_) {}
        final gapOffset = safeOffset;
        final realign = _realignRepeatedIntegrityGap(wal, gapOffset);
        _integrityGapRepeated = realign.repeated;
        safeOffset = realign.resume;
        _lastSegmentBoundaryOffset = safeOffset;
        onProgress?.call(safeOffset);
        await _recordPacketGap(directory, wal,
            expected: gapOffset,
            incoming: incoming is int ? incoming : null,
            resume: safeOffset,
            repeated: realign.repeated);
      }
      rethrow;
    } finally {
      _activeDownloadPath = null;
      pollTimer.cancel();
      // Do not let a failed STOP replace the typed integrity error, which is what
      // the caller classifies this read by. No new read starts this cycle after it,
      // though: the device may still be sending the old file.
      // A STOP that was refused, timed out or never sent reports false rather than
      // throwing (DeviceConnection.stopStorageSync); after a gap either one means the
      // device may still be sending the old file.
      try {
        if (!await connection.stopStorageSync() && integrityFailed) {
          _stopFailedAfterIntegrityGap = true;
          Logger.warning('SDCardWalSync: STOP after an integrity gap was not confirmed');
        }
      } catch (e) {
        if (!integrityFailed) rethrow;
        _stopFailedAfterIntegrityGap = true;
        Logger.warning('SDCardWalSync: STOP after native transfer failed: $e');
      }
    }

    final finalSize = outputFile.existsSync() ? await outputFile.length() : offset;
    _lastSegmentBoundaryOffset = finalSize;
    onProgress?.call(finalSize);

    if (SharedPreferencesUtil().adjustmentMode && outputFile.existsSync()) {
      try {
        final adjFolder = Directory('${directory.path}/adjustment_mode_segments/$subFolderPrefix');
        if (!await adjFolder.exists()) await adjFolder.create(recursive: true);
        await outputFile.copy('${adjFolder.path}/${timerStart}_${wal.sessionId ?? 0}.bin');
      } catch (e) {
        Logger.error('SDCardWalSync: failed to copy bin to adjustment_mode_segments: $e');
      }
    }

    await _completePacketGapCapture(directory, wal, outputFile, finalSize);

    await callback(outputFile, finalSize, timerStart, subFolder: subFolderPrefix);
  }

  /// Where each listed file stands on the phone, from its sealed chunks (§1 of the
  /// pipeline design), before anything is read or deleted: a file deleted on the phone
  /// (tombstoned) is not read again and its copy on the Omi is deleted; one the phone
  /// holds in full, or longer than the Omi now lists it, is complete or shortened at
  /// source and its copy deleted; any other resumes at its sealed end, or a resend
  /// before it after a repeated integrity gap. With a complete listing, a file the phone
  /// was still receiving that the Omi no longer lists is gone at its source.
  Future<void> _applySealedState({required bool listingComplete}) async {
    await beforeSealedSync?.call();
    final store = await _rawStore();
    if (!partsRecovered) {
      final ends = <RawFileKey, int>{};
      for (final w in [...await WalFileManager.loadWals(), ..._wals]) {
        if (w.walOffset > (ends[_keyOf(w)] ?? 0)) ends[_keyOf(w)] = w.walOffset;
      }
      final changed = await store.recover(persistedEnd: (key) => ends[key]);
      partsRecovered = true;
      if (changed.isNotEmpty) Logger.debug('SDCardWalSync: sealed the parts a crash left in ${changed.length} file(s)');
    }
    final sd = _wals.where((w) => w.storage == WalStorage.sdcard).toList();
    final entries = await Ledger(store.documentsPath).entriesFor(sd.map(_keyOf));
    final listed = <RawFileKey>{};
    for (final w in sd) {
      final key = _keyOf(w);
      listed.add(key);
      final file = await store.load(key);
      final sealed = file.length;
      if (entries[key]?.tombstone != null) {
        if (file.chunks.isNotEmpty && !file.lifecycle.isTerminal) {
          await store.setLifecycle(key, SourceLifecycle.sourceGone);
        }
        if (w.status != WalStatus.synced) {
          Logger.debug('SDCardWalSync: ts=${w.timerStart} was deleted on the phone; deleting it on the Omi, unread');
        }
        w.status = WalStatus.synced;
        continue;
      }
      if (sealed > 0 && sealed >= w.storageTotalBytes) {
        if (!file.lifecycle.isTerminal) {
          await store.setLifecycle(
              key, sealed == w.storageTotalBytes ? SourceLifecycle.complete : SourceLifecycle.shortenedAtSource,
              advertisedLength: w.storageTotalBytes);
        }
        w.walOffset = w.storageTotalBytes;
        w.status = WalStatus.synced;
        continue;
      }
      // A realignment asked for bytes before the sealed end: they are resent and compared.
      final resend = sealed - w.walOffset;
      if (resend <= 0 || resend > ChunkDownloader.maxResend) w.walOffset = sealed;
      w.nativeIntegrityVersion = 1;
    }
    if (!listingComplete) return;
    for (final key in await store.listKeys()) {
      if (listed.contains(key)) continue;
      final file = await store.load(key);
      if (file.chunks.isEmpty || file.lifecycle.isTerminal) continue;
      Logger.warning('SDCardWalSync: ${key.rel} left the Omi before it was all received (${file.length} B); '
          'what arrived is all there is');
      await store.setLifecycle(key, SourceLifecycle.sourceGone);
    }
  }

  /// The native read of [wal] into a part that is sealed however the transfer ends
  /// (ChunkDownloader): nothing already sealed is cut or written again.
  Future _readSealedLocked(
    DeviceConnection connection,
    Wal wal,
    Function(File f, int offset, int timerStart, {String? subFolder}) callback, {
    Function(int offset)? onProgress,
    int? overrideFileNum,
  }) async {
    final fileNum = overrideFileNum ?? wal.fileNum;
    final timerStart = wal.timerStart;
    if (_isCancelled) throw Exception("Cancelled");
    final store = await _rawStore();
    final key = _keyOf(wal);
    final directory = Directory(store.documentsPath);
    final sealed = (await store.load(key)).length;
    final resend = wal.walOffset < sealed ? sealed - wal.walOffset : 0;
    wal.nativeIntegrityVersion = 1;
    _activeTransferCompleter = null;

    final hostApi = BleHostApi();
    final part = store.partFile(key, sealed);
    int lastPolled = sealed;
    final pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isCancelled) {
        connection.stopStorageSync().catchError((_) => false);
        return;
      }
      try {
        final now = part.existsSync() ? sealed + part.lengthSync() : lastPolled;
        if (now > lastPolled) {
          lastPolled = now;
          _lastSegmentBoundaryOffset = now;
          onProgress?.call(now);
        }
      } catch (_) {}
    });

    _activeDownloadPath = part.path;
    _stopFailedAfterIntegrityGap = false;
    _integrityGapRepeated = false;
    var integrityFailed = false;
    int? realignTo;
    try {
      await ChunkDownloader(store).download(
        key,
        resend: resend > ChunkDownloader.maxResend ? 0 : resend,
        // An empty file on the Omi seals nothing and needs no manifest.
        advertisedLength: wal.storageTotalBytes > 0 ? wal.storageTotalBytes : null,
        transfer: (appendOffset, partPath, overlap) =>
            hostApi.downloadStorageChunk(_device!.id, fileNum, appendOffset, timerStart, partPath, overlap),
      );
    } on SourceMismatch catch (e) {
      Logger.error('SDCardWalSync: $e — the file is set aside; the phone keeps its copy');
      try {
        await onSourceMismatch?.call(key);
      } catch (err) {
        Logger.error('SDCardWalSync: could not set ${key.rel} aside: $err');
      }
      rethrow;
    } on PlatformException catch (e) {
      if (_isStorageIntegrityError(e)) {
        integrityFailed = true;
        final details = e.details;
        final incoming = details is Map ? details['incomingOffset'] : null;
        final gapOffset = (await store.load(key)).length;
        final realign = _realignRepeatedIntegrityGap(wal, gapOffset);
        _integrityGapRepeated = realign.repeated;
        realignTo = realign.resume;
        await _recordPacketGap(directory, wal,
            expected: gapOffset,
            incoming: incoming is int ? incoming : null,
            resume: realign.resume,
            repeated: realign.repeated);
      }
      rethrow;
    } finally {
      _activeDownloadPath = null;
      pollTimer.cancel();
      // What was accepted is sealed now: resume there, or, after a repeated gap, from
      // the resend before it.
      try {
        final sealedNow = (await store.load(key)).length;
        _lastSegmentBoundaryOffset = realignTo ?? sealedNow;
        onProgress?.call(sealedNow);
        if (realignTo != null) wal.walOffset = realignTo;
      } catch (_) {}
      try {
        await connection.stopStorageSync();
      } catch (e) {
        if (!integrityFailed) rethrow;
        _stopFailedAfterIntegrityGap = true;
        Logger.warning('SDCardWalSync: STOP after native transfer failed: $e');
      }
    }

    final file = await store.load(key);
    final finalSize = file.length;
    _lastSegmentBoundaryOffset = finalSize;
    if (wal.storageTotalBytes > 0 && finalSize >= wal.storageTotalBytes && !file.lifecycle.isTerminal) {
      await store.setLifecycle(key,
          finalSize == wal.storageTotalBytes ? SourceLifecycle.complete : SourceLifecycle.shortenedAtSource,
          advertisedLength: wal.storageTotalBytes);
    }
    final subFolderPrefix = key.folder;
    final first = File('${store.folderOf(key).path}/${key.chunkName(0)}');
    if (SharedPreferencesUtil().adjustmentMode && file.chunks.isNotEmpty) {
      try {
        final adjFolder = Directory('${directory.path}/adjustment_mode_segments/$subFolderPrefix');
        if (!await adjFolder.exists()) await adjFolder.create(recursive: true);
        final out = File('${adjFolder.path}/${key.chunkName(0)}').openWrite();
        try {
          for (final c in file.chunks) {
            await out.addStream(File(c.path).openRead());
          }
          await out.flush();
        } finally {
          await out.close();
        }
      } catch (e) {
        Logger.error('SDCardWalSync: failed to copy ${key.rel} to adjustment_mode_segments: $e');
      }
    }
    await _completePacketGapCapture(directory, wal, first, finalSize);
    await callback(first, finalSize, timerStart, subFolder: subFolderPrefix);
  }

  /// Returns the offset to resume [wal] from after a native integrity gap whose
  /// contiguous prefix ends at [gapOffset], and whether the gap repeated the previous
  /// one. A first gap resumes there. A second gap
  /// at the same offset resumes [integrityRealignBytes] earlier; the next read's
  /// _reconcileResumeOffset truncates the longer bin, and the device copy is
  /// immutable until delete, so the re-fetched bytes are identical.
  ({int resume, bool repeated}) _realignRepeatedIntegrityGap(Wal wal, int gapOffset) {
    final repeated = wal.lastIntegrityGapOffset == gapOffset;
    wal.lastIntegrityGapOffset = gapOffset;
    if (!repeated) return (resume: gapOffset, repeated: false);
    final resume = gapOffset > integrityRealignBytes ? gapOffset - integrityRealignBytes : 0;
    Logger.warning('SDCardWalSync: ts=${wal.timerStart} integrity gap repeated at $gapOffset — '
        'resuming from $resume so the device cuts packets on different boundaries');
    return (resume: resume, repeated: true);
  }

  String _packetGapCaptureName(Wal wal) => '${wal.timerStart}_${wal.sessionId ?? 0}';

  Map<String, Object?> _packetGapFileFields(Wal wal) => {
        'device': wal.device,
        'firmware': _device?.firmwareRevision,
        'timerStart': wal.timerStart,
        'sessionId': wal.sessionId,
        'fileNum': wal.fileNum,
        'storageTotalBytes': wal.storageTotalBytes,
      };

  Future<void> _appendPacketGapLog(Directory root, Map<String, Object?> event) =>
      File('${root.path}/log.jsonl').writeAsString('${jsonEncode(event)}\n', mode: FileMode.append, flush: true);

  /// Logs a native integrity gap to the [packetGapCaptureDir] log. A repeated gap
  /// also arms a capture of the file, which [_completePacketGapCapture] fills once
  /// the download completes. Best effort: evidence never fails a sync.
  Future<void> _recordPacketGap(
    Directory docs,
    Wal wal, {
    required int expected,
    required int? incoming,
    required int resume,
    required bool repeated,
  }) async {
    try {
      final root = Directory('${docs.path}/$packetGapCaptureDir');
      await root.create(recursive: true);
      final at = DateTime.now().toUtc().toIso8601String();
      await _appendPacketGapLog(root, {
        'event': repeated ? 'realign' : 'gap',
        'at': at,
        ..._packetGapFileFields(wal),
        'expectedOffset': expected,
        'incomingOffset': incoming,
        'resumeOffset': resume,
      });
      if (!repeated) return;

      final folder = Directory('${root.path}/${_packetGapCaptureName(wal)}');
      final manifest = File('${folder.path}/capture.json');
      final Map<String, dynamic> capture;
      if (await manifest.exists()) {
        capture = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      } else {
        final kept = await root.list().where((e) => e is Directory).length;
        if (kept >= maxPacketGapCaptures) {
          Logger.warning('SDCardWalSync: ts=${wal.timerStart} packet gap capture skipped — '
              '$kept captures already kept in $packetGapCaptureDir');
          return;
        }
        await folder.create();
        capture = {..._packetGapFileFields(wal), 'gaps': <Object?>[], 'capturedAt': null};
      }
      (capture['gaps'] as List).add({'expectedOffset': expected, 'incomingOffset': incoming, 'at': at});
      await manifest.writeAsString(jsonEncode(capture), flush: true);
      Logger.warning('SDCardWalSync: ts=${wal.timerStart} packet gap capture armed at $expected — '
          'the file is saved to $packetGapCaptureDir when it completes');
    } catch (e) {
      Logger.error('SDCardWalSync: packet gap log failed: $e');
    }
  }

  /// Copies a completed download whose capture [_recordPacketGap] armed, and logs
  /// the bytes of each lost range. Runs before the completion callback, so before the
  /// device copy is deleted and before processing can consume the bin.
  Future<void> _completePacketGapCapture(Directory docs, Wal wal, File bin, int size) async {
    if (wal.storageTotalBytes <= 0 || size < wal.storageTotalBytes) return;
    final root = Directory('${docs.path}/$packetGapCaptureDir');
    final name = _packetGapCaptureName(wal);
    final manifest = File('${root.path}/$name/capture.json');
    try {
      if (!await manifest.exists()) return;
      final capture = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      if (capture['capturedAt'] != null) return;
      await bin.copy('${root.path}/$name/${wal.getFileName()}');

      final lost = <Map<String, Object?>>[];
      final raf = await bin.open();
      try {
        for (final gap in (capture['gaps'] as List).cast<Map<String, dynamic>>()) {
          final start = gap['expectedOffset'];
          final incoming = gap['incomingOffset'];
          if (start is! int || incoming is! int || incoming <= start || start >= size) {
            lost.add(gap);
            continue;
          }
          var end = incoming < size ? incoming : size;
          if (end - start > _packetGapHexMaxBytes) end = start + _packetGapHexMaxBytes;
          await raf.setPosition(start);
          final bytes = await raf.read(end - start);
          lost.add({...gap, 'hex': bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')});
        }
      } finally {
        await raf.close();
      }

      final at = DateTime.now().toUtc().toIso8601String();
      capture['capturedAt'] = at;
      capture['size'] = size;
      await manifest.writeAsString(jsonEncode(capture), flush: true);
      await _appendPacketGapLog(root, {
        'event': 'captured',
        'at': at,
        ..._packetGapFileFields(wal),
        'size': size,
        'bin': '$name/${wal.getFileName()}',
        'lost': lost,
      });
      Logger.warning('SDCardWalSync: ts=${wal.timerStart} packet gap capture saved to $packetGapCaptureDir/$name');
    } catch (e) {
      Logger.error('SDCardWalSync: packet gap capture failed: $e');
    }
  }

  void _completeCancelIfPending() {
    final c = _cancelCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _cancelCompleter = null;
  }

  void _resetSyncState() {
    _isCancelled = false;
    _isSyncing = false;
    _totalBytesDownloaded = 0;
    _downloadStartTime = null;
    _currentSpeedKBps = 0.0;
    _syncProgressFraction = 0.0;
    _syncSessionTotal = 0;
    _cancelCompleter = null;
    _activeTransferCompleter = null;
  }

  // Record the latest 0..1 batch progress into the canonical session state. Called
  // wherever the sync loop reports progress, so the card + notification read one
  // consistent number regardless of which listener (foreground controller or
  // background notifier) is active at the moment.
  void _recordSyncProgress(double fraction) {
    _syncProgressFraction = fraction.clamp(0.0, 1.0);
  }

  Future<void> _checkDiskSpaceBeforeSync(int totalBytesToDownload) async {
    double? freeSpaceMb;
    try {
      freeSpaceMb = await DiskSpace.getFreeDiskSpace;
    } catch (_) {
      return; // Can't determine free space; proceed with sync.
    }
    if (freeSpaceMb != null) {
      final double requiredMb = (totalBytesToDownload * 1.1) / (1024 * 1024);
      if (freeSpaceMb < requiredMb) throw Exception("Phone Storage Full");
    }
  }

  void _updateSpeed(int bytesDownloaded) {
    _totalBytesDownloaded += bytesDownloaded;
    if (_downloadStartTime != null) {
      final elapsed = DateTime.now().difference(_downloadStartTime!).inMilliseconds / 1000.0;
      if (elapsed > 0) {
        _currentSpeedKBps = (_totalBytesDownloaded / 1024) / elapsed;
      }
    }
  }

  /// Deliberately NOT `async`: the in-flight claim below has to happen in the
  /// caller's own microtask. `_isSyncing` is set several awaits deep (after the
  /// connection lookup, and after up to 3s of storage-lock polling), so two calls
  /// entering together both cleared that guard and ran two download loops against
  /// the same index-0 queue. Claiming a Future synchronously closes that window.
  ///
  /// A sync arriving while one is running is **denied**, not joined. Joining
  /// looks helpful and is not: the running sync fixed its file list at its own
  /// CMD_LIST_FILES and never re-lists, so anything the device closed since is
  /// absent from it. The caller would be handed a stale result that reads as a
  /// fresh sync — the same lie as the phantom completion this class was fixed
  /// for, just harder to spot. Denying keeps one rule for every entry point and
  /// leaves the retry to [SharedPreferencesUtil.lastSyncSkipped], which marks the
  /// next check due immediately.
  @override
  Future<SyncLocalFilesResponse?> syncAll({
    IWalSyncProgressListener? progress,
  }) {
    if (_inFlightFullSync != null) {
      Logger.debug('SDCardWalSync: skipping syncAll — a sync is already in flight');
      return Future.value(null);
    }
    return _claimFullSync(_syncAllInner(progress: progress));
  }

  /// The synchronous claim on a full sync. Its job is to make "is a sync running?"
  /// answerable without an await, so two callers entering together cannot both
  /// start one. Cleared on completion, and only if this run is still the current
  /// one.
  Future<SyncLocalFilesResponse?>? _inFlightFullSync;

  Future<SyncLocalFilesResponse?> _claimFullSync(Future<SyncLocalFilesResponse?> run) {
    _inFlightFullSync = run;
    // whenComplete FIRST, registered here at claim time, so the slot is free the
    // moment the run settles rather than a couple of microtasks later — otherwise
    // a caller arriving right after a sync finished is denied for no reason.
    // Swallow after, on the cleanup branch only: `run` is returned intact so a
    // real caller still sees the error, and without the onError a throwing sync
    // surfaces as an unhandled async error.
    unawaited(run.whenComplete(() {
      if (identical(_inFlightFullSync, run)) _inFlightFullSync = null;
    }).then<void>((_) {}, onError: (_) {}));
    return run;
  }

  Future<SyncLocalFilesResponse?> _syncAllInner({
    IWalSyncProgressListener? progress,
  }) async {
    if (_isSyncing || _device == null) {
      Logger.debug(
          'SDCardWalSync: skipping syncAll — ${_isSyncing ? 'a sync is already in flight' : 'no device registered yet'}');
      return null;
    }

    final dev = _device!;
    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) throw DeviceConnectionException('No connection');

    // A brief non-sync storage op (e.g. refreshStorageStats when the device
    // settings page opens) can hold the lock for a second or two. Returning null
    // here reads as "no new segments" to the pipeline, which then proceeds to
    // processing as if the sync ran — so a real sync gets silently skipped. Wait a
    // bounded time for a transient holder to clear before giving up; a genuinely
    // stuck holder still skips gracefully (and acquireStorageLock below carries its
    // own 10s timeout as a backstop).
    if (connection.isStorageBusy) {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (connection.isStorageBusy && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
      if (connection.isStorageBusy) {
        Logger.debug('Storage busy, skipping: syncAll (lock held >3s)');
        return null;
      }
    }

    _resetSyncState();
    _isSyncing = true;

    await connection.acquireStorageLock('syncAll');
    try {
      return await _syncAllLocked(connection, dev.id, progress: progress);
    } finally {
      _isSyncing = false;
      listener.onSyncFinished();
      _completeCancelIfPending();
      connection.releaseStorageLock();
    }
  }

  Future<SyncLocalFilesResponse?> _syncAllLocked(
    DeviceConnection connection,
    String deviceId, {
    ({List<Wal> wals, bool complete, ({int atMs, int link, int linkSinceMs})? on})? prefetchedWals,
    IWalSyncProgressListener? progress,
  }) async {
    _lastStorageStats = null;
    final result = await _syncAllFilesLocked(connection, deviceId, prefetchedWals: prefetchedWals, progress: progress);
    if (result != null) {
      // Files processing has stopped waiting for, which no longer make a sync partial
      // (see [givenUpOn]), are shown on their own in the idle notification and on the
      // recordings page, with how much more the Omi can record before it overwrites
      // them: only a complete download deletes them, so that is the one way they end.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final stuck = _wals
          .where((w) => w.storage == WalStorage.sdcard && w.status == WalStatus.miss && givenUpOn(w, nowMs))
          .length;
      if (stuck > 0 && _lastStorageStats == null) await _updateStorageStatsLocked(connection);
      final prefs = SharedPreferencesUtil();
      prefs.lastSyncStuckFiles = stuck;
      prefs.lastSyncStuckOverwriteMinutes = stuck > 0 ? overwriteMinutesLeft(_lastStorageStats) : -1;
    }
    return result;
  }

  Future<SyncLocalFilesResponse?> _syncAllFilesLocked(
    DeviceConnection connection,
    String deviceId, {
    ({List<Wal> wals, bool complete, ({int atMs, int link, int linkSinceMs})? on})? prefetchedWals,
    IWalSyncProgressListener? progress,
  }) async {
    final listed = prefetchedWals ?? await _getMissingWalsLocked(connection, deviceId);
    // No answer means we do not know what the device holds — which is NOT the same
    // as it holding nothing. Reporting the empty response here is what let a failed
    // listing paint a completed sync: the UI said "nothing to sync" and the
    // lastSyncCompletedMs stamp talked the next automatic attempt out of running for
    // a full interval, while the recordings sat on the card. `null` = did not run,
    // which the callers already handle as a skip and retry immediately.
    // _wals is left as it was on purpose: the last known list (and its resume
    // offsets) is better than an empty one we have no evidence for.
    if (listed == null) {
      Logger.warning('SDCardWalSync: sync did not run — the device did not answer CMD_LIST_FILES');
      await _recoverAfterFailedListing(connection);
      return null;
    }
    _noteStorageReplyHeard();
    _wals = listed.wals;
    _listedOn = listed.complete ? listed.on : null;
    if (RawChunkStore.enabled) await _applySealedState(listingComplete: listed.complete);
    // A listing the device could not deliver in full names only a prefix of the
    // card, so whatever this run fetches, it did not fetch everything. That is the
    // definition of a partial sync — and it carries the consequence that matters:
    // the caller must not finalize drafts whose tail may sit in a bin this listing
    // never named. The files it DID name are still synced; the rest come back in
    // the next listing, which is how a backlog past one packet drains.
    bool listingIncomplete = !listed.complete;
    listener.onWalUpdated();

    if (_isCancelled) return null;

    // Files deleted from the device this session, by their index in the listing above.
    // See [_currentIndex].
    final deletedListIndices = <int>[];

    // Retry the delete for files we already hold in full that the device is still
    // listing (see the `synced` carry in _buildWalsFromFilesLocked). This has to run
    // BEFORE the `miss` filter and its empty-list early return below, or a card holding
    // nothing but already-synced files would never be drained again.
    final retried = await _retryPendingDeletesLocked(connection, deviceId, deletedListIndices);
    bool receivedAllDeleted = retried.allDeleted;
    if (retried.uncertain && !_isCancelled) {
      // A failed delete may have taken anyway, and then every index after it is one too
      // high. Listing again says where each file is now: a file whose delete did take is
      // gone from it, and one whose delete did not is carried as `synced` again, for the
      // next sync to retry. Deletes are not retried a second time in this cycle.
      Logger.warning('SDCardWalSync: a retried delete failed and may still have taken — listing again before '
          'reading by index');
      final relisted = await _getMissingWalsLocked(connection, deviceId);
      if (relisted == null) {
        Logger.warning('SDCardWalSync: the second listing went unanswered — ending this cycle');
        await _updateStorageStatsLocked(connection);
        return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: [], isPartial: true);
      }
      _wals = relisted.wals;
      _listedOn = relisted.complete ? relisted.on : null;
      if (RawChunkStore.enabled) await _applySealedState(listingComplete: relisted.complete);
      listingIncomplete = !relisted.complete;
      deletedListIndices.clear();
      receivedAllDeleted = !_wals.any((w) => w.storage == WalStorage.sdcard && w.status == WalStatus.synced);
      listener.onWalUpdated();
    }
    final bool cardNotDrained = listingIncomplete || !receivedAllDeleted;

    // The firmware sorts files ascending by timestamp: index 0 = oldest completed
    // recording, highest index = newest. The active TMP_ file is excluded from the
    // list entirely by the firmware, so no active-file filtering is needed here.
    final wals = _wals.where((w) {
      return w.status == WalStatus.miss && w.storage == WalStorage.sdcard;
    }).toList();

    // The listing is the device's own word on what it still holds, so it is saved before
    // anything else can end this cycle. Unsaved, a file that had left the device since
    // (cleared, or overwritten while stuck) stayed in wals.json as still waiting whenever
    // the cycle read nothing — an empty card, or a disconnect before the first read — and
    // heldBackBinRelPaths, which reads it, kept holding the newer audio of that boot back,
    // with no failures to give up on, until a later sync saved the list.
    await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));

    // Non-null: the device WAS asked (CMD_LIST_FILES went out above) and holds
    // nothing syncable. That is a completed sync, and it must not be reported as
    // a skip — null is reserved for "the sync never ran", which is what the
    // callers key their "Skipped" state and their lastSyncCompletedMs stamp off.
    if (wals.isEmpty) {
      return SyncLocalFilesResponse(
        newConversationIds: [],
        updatedConversationIds: [],
        isPartial: cardNotDrained,
      );
    }

    // Oldest first, except that files which failed in an earlier cycle go after the
    // rest, so one that keeps failing cannot spend each cycle before newer audio gets its
    // turn. Every file is read and deleted at its own index, so the order decides only
    // what arrives first: processing waits for a missing older piece on its own (see
    // heldBackBinRelPaths), and recordings are still built in order.
    wals.sort((a, b) {
      final retryA = a.syncFailCount > 0 ? 1 : 0;
      final retryB = b.syncFailCount > 0 ? 1 : 0;
      if (retryA != retryB) return retryA.compareTo(retryB);
      return a.fileNum.compareTo(b.fileNum);
    });

    bool anyPartial = cardNotDrained;
    _downloadStartTime = DateTime.now();

    // Protocol settle delay: give firmware storage thread a moment to finish its
    // CMD_LIST_FILES cleanup (folder closing, EOT notify) before starting first read.
    await Future.delayed(const Duration(milliseconds: 200));

    bool anyDeleted = deletedListIndices.isNotEmpty;
    int failuresInARow = 0;
    for (int i = 0; i < wals.length; i++) {
      final wal = wals[i];
      // Stopping with files still to read leaves them on the device: partial, never
      // Complete. A disconnect in the moment after the listing used to report a sync that
      // had read nothing as complete — and a Force Sync then closed the conversation that
      // the rest of the audio still belonged to.
      if (_isCancelled) {
        anyPartial = true;
        break;
      }

      // Abort if device disconnected between files
      if (!await connection.isConnected()) {
        Logger.debug('SDCardWalSync: Connection lost during syncAll, aborting loop');
        anyPartial = true;
        break;
      }

      if (failuresInARow >= _maxFailuresInARow) {
        Logger.warning('SDCardWalSync: $failuresInARow files failed in a row — ending this cycle; '
            '${wals.length - i} file(s) wait on the device for the next sync');
        anyPartial = true;
        break;
      }

      final index = _currentIndex(wal, deletedListIndices);
      wal.isSyncing = true;
      wal.syncStartedAt = DateTime.now();
      listener.onWalUpdated();

      // Reconcile BEFORE the snapshot below: initialOffset must be this attempt's
      // real resume point, or the forward-progress check misjudges a rewound read.
      // See _reconcileWalOffsetToDisk.
      await _reconcileWalOffsetToDisk(wal);

      final initialOffset = wal.walOffset;
      int lastOffset = initialOffset;
      _lastSegmentBoundaryOffset =
          initialOffset; // reset per-file so a failure on file[i] can't inherit file[i-1]'s offset
      await _checkDiskSpaceBeforeSync(wal.storageTotalBytes - initialOffset);

      try {
        const int maxGapRetries = 3;
        const int maxAckRetries = 3;
        const int maxStallRetries = 2;
        int gapRetries = 0;
        int ackRetries = 0;
        int stallRetries = 0;
        bool transferred = false;
        while (!transferred) {
          if (_isCancelled) throw Exception("Cancelled");
          try {
            await _readStorageBytesToFileLocked(
              connection,
              wal,
              (File file, int offset, int timerStart, {String? subFolder}) async {
                if (_isCancelled) throw Exception("Cancelled");
                listener.onWalUpdated();
              },
              onProgress: (offset) {
                _updateSpeed(offset - lastOffset);
                lastOffset = offset;
                wal.walOffset = offset;
                // Throttle persistence to ~1 Hz. onProgress fires per BLE packet
                // (~50/sec); without throttling this floods disk and logs with
                // identical writes. The truncate-on-resume guard at the start of
                // _readStorageBytesToFileLocked still bounds re-fetch on crash to
                // one persist-window of bytes (tens of KB at BLE rates). End-of-
                // file state transitions (deletion, transfer-failure, end-of-
                // sync) still persist immediately below.
                final now = DateTime.now();
                if (_lastWalPersistAt == null || now.difference(_lastWalPersistAt!) >= _walPersistInterval) {
                  _lastWalPersistAt = now;
                  WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
                }
                final double withinWal = (wal.storageTotalBytes > initialOffset)
                    ? (offset - initialOffset) / (wal.storageTotalBytes - initialOffset)
                    : 1.0;
                final double clamped = ((i + (withinWal.clamp(0.0, 1.0) * 0.9)) / wals.length).clamp(0.0, 1.0);
                _recordSyncProgress(clamped);
                progress?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
                _globalProgressListener?.onWalSyncedProgress(clamped, speedKBps: _currentSpeedKBps);
              },
              overrideFileNum: index,
            );
            transferred = true;
          } on ProtocolGapException catch (e) {
            gapRetries++;
            if (gapRetries > maxGapRetries) rethrow;
            wal.walOffset = e.incoming;
            lastOffset = e.incoming;
            _lastSegmentBoundaryOffset = e.incoming;
            await connection.stopStorageSync();
            await Future.delayed(const Duration(milliseconds: 200));
          } on AckException catch (e) {
            // ACK 7 = FILE_NOT_FOUND, often due to SD contention.
            if (e.code == 7 && ackRetries < maxAckRetries) {
              ackRetries++;
              Logger.debug(
                  'SDCardWalSync: Error ACK 7 for fileNum=${wal.fileNum}, retrying ($ackRetries/$maxAckRetries) after 500ms');
              await connection.stopStorageSync();
              await Future.delayed(const Duration(milliseconds: 500));
              continue;
            }
            rethrow;
          } catch (e) {
            if (e.toString().contains('Transfer stalled') && stallRetries < maxStallRetries) {
              stallRetries++;
              Logger.debug(
                  'SDCardWalSync: Transfer stalled for fileNum=${wal.fileNum}, retrying ($stallRetries/$maxStallRetries) after 1s');
              await connection.stopStorageSync();
              await Future.delayed(const Duration(seconds: 1));
              continue;
            }
            rethrow;
          }
        }

        if (_isCancelled) throw Exception("Cancelled");

        // Completeness guard. The firmware advertised wal.storageTotalBytes for this
        // file in CMD_LIST_FILES, but a transfer can "complete" (clean EOT / the
        // native download returns) having delivered FEWER bytes — e.g. the firmware
        // sent an empty EOT for a file whose cached size went stale after a rotation,
        // returned res=0 / 0-bytes when the file rotated under the read handle, or hit
        // a mid-file read error (see storage.c / sd_card.c). wal.walOffset now holds
        // the bytes actually written to the local file (the native path sets it from
        // the on-disk size). Marking such a short read "synced" and deleting the
        // device-side copy turns a transient read glitch into PERMANENT data loss —
        // this is exactly how a Priority Recording vanished (device had 468 KB, the
        // read returned ~0, the file was deleted). Only accept + delete when the whole
        // file arrived; otherwise leave it as `miss` so the next sync retries. The
        // device copy is immutable until we send CMD_DELETE_FILE, so the retry is safe.
        if (wal.storageTotalBytes > 0 && wal.walOffset < wal.storageTotalBytes) {
          _countFailedAttempt(wal, madeProgress: wal.walOffset > initialOffset);
          wal.status = WalStatus.miss;
          wal.isSyncing = false;
          listener.onWalUpdated();
          if (!givenUpOn(wal, DateTime.now().millisecondsSinceEpoch)) anyPartial = true;
          failuresInARow++;
          Logger.error('SDCardWalSync: incomplete transfer for ts=${wal.timerStart} '
              '(${wal.walOffset}/${wal.storageTotalBytes} B, strike ${wal.syncFailCount}) — kept on the device '
              'for the next sync; moving on to the next file');
          WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
          continue;
        }

        // Full file received — clear any prior strikes and finalize.
        wal.syncFailCount = 0;
        wal.status = WalStatus.synced;
        wal.isSyncing = false;
        failuresInARow = 0;
        listener.onWalUpdated();
        // The native downloader is silent per-packet, so log the completion here:
        // this confirms the whole file arrived (received == device-advertised) right
        // before it's deleted, making a healthy sync verifiable from the log alone.
        Logger.debug('SDCardWalSync: full file received ts=${wal.timerStart} '
            '(${wal.walOffset}/${wal.storageTotalBytes} B) — synced, deleting');

        // Diagnostic: a bin the DEVICE itself advertised as 0 bytes in CMD_LIST_FILES
        // means the firmware opened+rotated the file but never persisted a single
        // frame into it. That is the signature of a lost Priority Recording — the
        // 0xFFFFFFF8 start marker and its force-captured audio were dropped at the
        // rotation, so an empty bin rotates through here and is deleted as "synced".
        // Surface it loudly so this is traceable from the app log alone, with no
        // RTT/serial capture. storageTotalBytes = device-advertised size; walOffset =
        // bytes actually received (both ~0 here → the loss is on-device, not in transit).
        if (wal.storageTotalBytes == 0) {
          Logger.warning('SDCardWalSync: ts=${wal.timerStart} synced EMPTY — device advertised 0 B '
              '(firmware wrote nothing to this bin; a lost priority marker/recording rotates through here)');
        }

        // Delete immediately so a disconnect won't re-sync this file next session.
        try {
          await _deleteWalLocked(connection, wal, overrideFileNum: index, skipSave: true);
          deletedListIndices.add(wal.fileNum);
          anyDeleted = true;
          // Settle delay: give the SD worker time to finish metadata updates before requesting next file
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          Logger.error('SDCardWalSync: deletion failed for index=$index after transfer: $e — kept as received; '
              'the next sync retries the delete');
          anyPartial = true;
          // Persist so the `synced` status set above survives an app kill. It is the only
          // record that this file's bytes are already on the phone; losing it re-downloads
          // the file — and by then processing has pruned the local bin, so the resume
          // rewinds to 0 and the audio is decoded twice.
          await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
          // A delete whose reply was lost may still have taken, and then every later file
          // sits one place lower than _currentIndex says. Older firmware reads whatever is
          // at the index it is given, so reading on could fetch one file's bytes into
          // another's bin. The rest wait for the next sync, which lists them afresh.
          final remaining = wals.length - i - 1;
          if (remaining > 0) {
            Logger.warning('SDCardWalSync: ending this cycle after a failed delete — $remaining file(s) wait for '
                'the next sync');
          }
          break;
        }

        final double fileDone = ((i + 1.0) / wals.length).clamp(0.0, 1.0);
        _recordSyncProgress(fileDone);
        progress?.onWalSyncedProgress(fileDone, speedKBps: _currentSpeedKBps);
        _globalProgressListener?.onWalSyncedProgress(fileDone, speedKBps: _currentSpeedKBps);
      } catch (e) {
        Logger.error(
            'SDCardWalSync: transfer failed for fileNum=${wal.fileNum} (index $index) ts=${wal.timerStart}: $e');
        wal.walOffset = _lastSegmentBoundaryOffset;
        wal.status = WalStatus.miss;
        wal.isSyncing = false;
        listener.onWalUpdated();

        if (_isCancelled) {
          anyPartial = true;
          await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
          break;
        }

        // Give a small window for connection state to update in the provider/service
        await Future.delayed(const Duration(milliseconds: 100));
        if (!await connection.isConnected()) {
          // Do not advance to another WAL after transport loss. Stream closed without EOT
          // matches definiteTransportError below, so waiting would only delay recycling and
          // breaking. The next connection retries this file from its persisted offset;
          // measured median reconnection was 8.2 s, against ~33 minutes until the next
          // scheduled sync.
          Logger.debug('SDCardWalSync: Connection lost after failure, aborting syncAll');
          anyPartial = true;
          await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
          break;
        }

        // Re-check cancellation after the awaits above: cancelSync() may have set
        // _isCancelled during the delay / isConnected() window. A cancellation is not
        // the file's fault, so it must not count against it.
        if (_isCancelled) {
          anyPartial = true;
          await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
          break;
        }

        // A DEFINITE transport/GATT error (op timeout, missing characteristic, mid-
        // download drop) is a wedged (connected-but-dead) GATT — the ACL link is up so
        // the isConnected() check above doesn't catch it, but GATT ops are dead. It is
        // NOT this file's fault, so it does not count against it. Recycle the link so the
        // next cycle rides a FRESH GATT instead of hammering the wedge, and end the batch
        // (the persisted offset resumes this file next cycle). An ambiguous 15s "Transfer
        // stalled" is intentionally NOT treated here: it may be a single unreadable file,
        // which is skipped below, and a link-wide stall wedge is already recovered by the
        // pipeline stall watchdog, which recycles.
        final errStr = e.toString();
        final bool definiteTransportError = e is TimeoutException ||
            errStr.contains('Future not completed') ||
            errStr.contains('Stream closed without EOT') ||
            errStr.contains('Not found') ||
            errStr.contains('Characteristic not available') ||
            errStr.contains('notification-subscription');
        if (definiteTransportError) {
          // A plain recycle, not _recoverStorageReplies: a transfer that dies mid-file is
          // the wedged-GATT signature and is recovered every time. Routing it through that
          // method's once-per-episode limit would change nothing anyway — a transfer only
          // starts after a listing the device answered, which re-arms it — and this path
          // cannot feed the reconnect-and-adopt loop the limit exists to break: the run it
          // ends reports as having run, so no skip is recorded for _handleDeviceConnected.
          final recycle = _recycleConnection;
          if (recycle != null) {
            Logger.warning('SDCardWalSync: transfer failed with a transport-wedge signal ($e) — '
                'recycling connection, not charging file ts=${wal.timerStart}');
            unawaited(recycle());
          }
          anyPartial = true;
          await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
          break;
        }

        // Anything else is this file's own failure — an integrity gap, an ACK 7 or a
        // stall that outlasted the retries above, a read that would not start. The file
        // stays on the device and is retried next sync (a repeated gap resumes realigned,
        // see _realignRepeatedIntegrityGap), and the batch moves on to the next file.
        //
        // Except a gap that did not repeat: one lost packet is the link's doing (a weak
        // background link loses them anywhere), and charging it started the clock that lets
        // processing stop waiting for the file — splitting a conversation over link noise.
        // A gap lost again at the same place is the file's: it is what realigning is for,
        // and if that does not get past it, processing must not wait for it for ever.
        // Progress still resets the count, as it does for any other failure.
        final madeProgress = _lastSegmentBoundaryOffset > initialOffset;
        if (_isStorageIntegrityError(e) && !_integrityGapRepeated) {
          if (madeProgress) wal.syncFailCount = 0;
        } else {
          _countFailedAttempt(wal, madeProgress: madeProgress);
        }
        if (!givenUpOn(wal, DateTime.now().millisecondsSinceEpoch)) anyPartial = true;
        failuresInARow++;
        await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
        if (_isStorageIntegrityError(e) && _stopFailedAfterIntegrityGap) {
          // The STOP for this gap did not take, so the device may still be sending this
          // file. A read started now could take those packets for its own.
          Logger.warning('SDCardWalSync: ts=${wal.timerStart} ended on an integrity gap whose STOP failed — '
              'ending this cycle rather than start another read under it');
          anyPartial = true; // the files after it were not read
          break;
        }
        Logger.warning('SDCardWalSync: ts=${wal.timerStart} stays on the device for the next sync '
            '(strike ${wal.syncFailCount}) — moving on to the next file');
      }
    }

    // Persist the trimmed WAL list only when something was actually deleted,
    // but always refresh storage stats so File Count / Free Space stay current
    // even on transfer-only or all-failed cycles.
    if (anyDeleted) {
      await WalFileManager.saveWals(_wals, deviceId: deviceId).catchError((_) => Future.value(false));
    }
    await _updateStorageStatsLocked(connection);

    return SyncLocalFilesResponse(
      newConversationIds: [],
      updatedConversationIds: [],
      isPartial: anyPartial,
    );
  }

  @override
  Future<SyncLocalFilesResponse?> syncWal({
    required Wal wal,
    IWalSyncProgressListener? progress,
  }) async {
    if (_isSyncing) {
      Logger.debug('SDCardWalSync: skipping syncWal — a sync is already in flight');
      return null;
    }

    final connection = _device != null
        ? (_connectionProvider != null
            ? await _connectionProvider!(_device!.id)
            : await ServiceManager.instance().device.ensureConnection(_device!.id))
        : null;
    if (connection == null) throw DeviceConnectionException('No connection');

    if (connection.isStorageBusy) {
      Logger.debug('Storage busy, skipping: syncWal');
      return null;
    }

    _resetSyncState();
    _isSyncing = true;

    await connection.acquireStorageLock('syncWal');
    try {
      return await _syncWalLocked(connection, wal, progress: progress);
    } finally {
      _isSyncing = false;
      listener.onSyncFinished();
      _completeCancelIfPending();
      connection.releaseStorageLock();
    }
  }

  Future<SyncLocalFilesResponse?> _syncWalLocked(
    DeviceConnection connection,
    Wal wal, {
    IWalSyncProgressListener? progress,
  }) async {
    // getMissingWals returns rebuilt objects. Persist THIS attempt's prefix and
    // integrity version, including when the caller supplied a detached WAL.
    _wals.removeWhere((w) => w.device == wal.device && w.relativeBinPath == wal.relativeBinPath);
    _wals.add(wal);
    wal.isSyncing = true;
    wal.syncStartedAt = DateTime.now();
    listener.onWalUpdated();

    // Reconcile before the snapshot, as in _syncAllLocked: initialOffset sizes the
    // disk reservation and the progress %, both of which a rewind would skew.
    await _reconcileWalOffsetToDisk(wal);

    final initialOffset = wal.walOffset;
    int lastOffset = initialOffset;
    _lastSegmentBoundaryOffset = initialOffset;
    await _checkDiskSpaceBeforeSync(wal.storageTotalBytes - initialOffset);
    _downloadStartTime = DateTime.now();

    try {
      const int maxGapRetries = 3;
      int gapRetries = 0;
      bool transferred = false;
      while (!transferred) {
        if (_isCancelled) throw Exception("Cancelled");
        try {
          await _readStorageBytesToFileLocked(
            connection,
            wal,
            (File file, int offset, int timerStart, {String? subFolder}) async {
              if (_isCancelled) throw Exception("Cancelled");
              listener.onWalUpdated();
            },
            onProgress: (offset) {
              _updateSpeed(offset - lastOffset);
              lastOffset = offset;
              wal.walOffset = offset;
              final double progressPercent = (wal.storageTotalBytes > initialOffset)
                  ? (offset - initialOffset) / (wal.storageTotalBytes - initialOffset)
                  : 1.0;
              final double clamped = progressPercent.clamp(0.0, 1.0);
              _recordSyncProgress(clamped);
              progress?.onWalSyncedProgress(
                clamped,
                speedKBps: _currentSpeedKBps,
              );
              _globalProgressListener?.onWalSyncedProgress(
                clamped,
                speedKBps: _currentSpeedKBps,
              );
            },
          );
          transferred = true;
        } on ProtocolGapException catch (e) {
          gapRetries++;
          if (gapRetries > maxGapRetries) rethrow;
          wal.walOffset = e.incoming;
          lastOffset = e.incoming;
          _lastSegmentBoundaryOffset = e.incoming;
          await connection.stopStorageSync();
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (_isCancelled) throw Exception("Cancelled");

      // Completeness guard, mirroring _syncAllLocked: a transfer can "complete"
      // (clean EOT) having delivered fewer bytes than the device advertised in
      // CMD_LIST_FILES — an empty/short read after a rotation, etc. Deleting the
      // device-side file on a short read is permanent data loss, so only delete when
      // the whole file arrived; otherwise leave the WAL `miss` so a later sync retries
      // (the device copy is immutable until CMD_DELETE_FILE, so the retry is safe).
      // Unlike the fast path there is no index-0 queue to unblock here, so no
      // poison-drop — just skip the delete and report the sync as partial.
      if (wal.storageTotalBytes > 0 && wal.walOffset < wal.storageTotalBytes) {
        wal.syncFailCount += 1;
        wal.failingSinceMs ??= DateTime.now().millisecondsSinceEpoch;
        wal.status = WalStatus.miss;
        wal.isSyncing = false;
        listener.onWalUpdated();
        Logger.error('SDCardWalSync: syncWal incomplete for ts=${wal.timerStart} '
            '(${wal.walOffset}/${wal.storageTotalBytes} B) — NOT deleting; leaving on device to retry');
        // Persist the strike + offset (onWalUpdated is only a notification) so the
        // failure count survives a refresh/restart. Awaited (unlike the batch loop's
        // throttled fire-and-forget saves) because this is a single terminal op that
        // returns right after — the write must land before we hand back. The success
        // path persists via _deleteWalLocked.
        await WalFileManager.saveWals(_wals, deviceId: wal.device).catchError((_) => Future.value(false));
        return SyncLocalFilesResponse(
          newConversationIds: [],
          updatedConversationIds: [],
          isPartial: true,
        );
      }

      wal.syncFailCount = 0;
      // Mirror the fast path and record that every byte is here BEFORE asking the
      // device to drop its copy. A rejected delete THROWS, and the catch below rewinds
      // walOffset to the last segment boundary and marks the WAL `miss` — the right
      // response to a failed transfer, the wrong one to a failed delete, which happens
      // only after the whole file has landed. Left that way the next sync re-downloads
      // a file we already hold and decodes it a second time.
      wal.status = WalStatus.synced;
      wal.isSyncing = false;
      try {
        await _deleteWalLocked(connection, wal);
      } catch (e) {
        // Keep the `synced` status: _buildWalsFromFilesLocked carries it across the
        // next listing rebuild, and _retryPendingDeletesLocked reissues the delete.
        Logger.error('SDCardWalSync: syncWal delete rejected for ts=${wal.timerStart}: $e — '
            'keeping the WAL synced so the next sync retries the delete, not the download');
        listener.onWalUpdated();
        await WalFileManager.saveWals(_wals, deviceId: wal.device).catchError((_) => Future.value(false));
        return SyncLocalFilesResponse(
          newConversationIds: [],
          updatedConversationIds: [],
          isPartial: true,
        );
      }
    } catch (e) {
      wal.walOffset = _lastSegmentBoundaryOffset;
      wal.isSyncing = false;
      wal.status = WalStatus.miss;
      listener.onWalUpdated();
      await WalFileManager.saveWals(_wals, deviceId: wal.device).catchError((_) => Future.value(false));
      rethrow;
    }

    return SyncLocalFilesResponse(
      newConversationIds: [],
      updatedConversationIds: [],
    );
  }

  /// Force Sync. Non-async, and denied while a sync is running, exactly as
  /// [syncAll] is — see the note there for both reasons.
  ///
  /// It matters twice over here: sealing the active bin is the whole point of the
  /// call, and it is what lets the caller finalize drafts, so a run that returned
  /// without a rotate would not merely be stale — it would finalize a recording
  /// whose tail is still on the device. The UI says a sync is in progress; see
  /// `RecordingsPage._forceSyncButtonPressed`.
  @override
  Future<SyncLocalFilesResponse?> rotateAndSync({
    IWalSyncProgressListener? progress,
  }) {
    if (_inFlightFullSync != null) {
      Logger.debug('SDCardWalSync: skipping rotateAndSync — a sync is already in flight');
      return Future.value(null);
    }
    return _claimFullSync(_rotateAndSyncInner(progress: progress));
  }

  /// Reconnect once because a storage command heard nothing back.
  ///
  /// The failure this exists for is a stale notification subscription — the link is up,
  /// commands go out, and no reply ever reaches us (seen after Bluetooth was toggled
  /// mid-download). A fresh GATT cures that, and nothing short of one does.
  ///
  /// Two limits, and both are load-bearing:
  ///
  /// * Only while the link is up. A link that is already down is native's to bring back;
  ///   recycling it forces a Dart connect that holds DeviceService's mutex for up to the
  ///   75 s connect backstop, stalling every ensureConnection caller behind it.
  /// * Only once per failure episode. If the reconnect did not help, another will not
  ///   either — a hung storage thread is not a stale subscription — and each one is
  ///   worse than useless in the background: the failed run records a skip, so
  ///   _handleDeviceConnected adopts the returning link as a sync that is due, which fails
  ///   and reconnects again, around the clock. Any reply from the device re-arms it
  ///   ([_noteStorageReplyHeard]).
  ///
  /// A device that answered and refused (STORAGE_NOT_READY: the SD card is not mounted,
  /// or has failed) never reaches here — see [_recoverAfterFailedListing].
  Future<void> _recoverStorageReplies(DeviceConnection connection, String reason) async {
    final recycle = _recycleConnection;
    if (_isCancelled || recycle == null) return;
    if (!_storageRecoveryArmed) {
      Logger.warning('SDCardWalSync: $reason — already reconnected once for this without a reply since; '
          'not reconnecting again');
      return;
    }
    if (!await connection.isConnected()) {
      Logger.warning('SDCardWalSync: $reason — the link is already down; leaving reconnection to native');
      return;
    }
    _storageRecoveryArmed = false;
    Logger.warning('SDCardWalSync: $reason — recycling the connection');
    unawaited(recycle().catchError((Object e) {
      Logger.warning('SDCardWalSync: connection recovery failed: $e');
      return false;
    }));
  }

  /// The device answered a storage command, so its reply channel works.
  void _noteStorageReplyHeard() => _storageRecoveryArmed = true;

  /// A listing that came back null: reconnect only if nothing came back at all.
  Future<void> _recoverAfterFailedListing(DeviceConnection connection) async {
    if (connection.lastListingHeardDevice) {
      Logger.warning('SDCardWalSync: the device answered CMD_LIST_FILES but refused it — its replies are '
          'arriving, so a reconnect would not help; not reconnecting');
      _noteStorageReplyHeard();
      return;
    }
    await _recoverStorageReplies(connection, 'CMD_LIST_FILES got no reply at all');
  }

  Future<SyncLocalFilesResponse?> _rotateAndSyncInner({
    IWalSyncProgressListener? progress,
  }) async {
    if (_isSyncing || _device == null) {
      Logger.debug(
          'SDCardWalSync: skipping rotateAndSync — ${_isSyncing ? 'a sync is already in flight' : 'no device registered yet'}');
      return null;
    }

    final dev = _device!;
    // Honour _connectionProvider like every other entry point in this class does.
    // This one reached for ServiceManager directly, which made the rotate path the
    // only one unreachable from a test — so nothing covered the flag that licenses
    // Force Sync to finalize drafts.
    final connection = _connectionProvider != null
        ? await _connectionProvider!(dev.id)
        : await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) throw DeviceConnectionException('No connection');

    if (connection.isStorageBusy) {
      Logger.debug('Storage busy, skipping: rotateAndSync');
      return null;
    }

    _resetSyncState();
    _isSyncing = true;

    await connection.acquireStorageLock('rotateAndSync');
    try {
      if (_isCancelled) return null;

      bool rotated = false;
      for (int i = 0; i < 3; i++) {
        if (_isCancelled) return null;
        try {
          rotated = await connection.rotateFile();
        } on StorageRotationNotStartedException catch (e) {
          Logger.warning('SDCardWalSync: $e — no rotation to retry or reconcile');
          await _recoverStorageReplies(connection, 'rotation could not start');
          // No command was sent. The controller treats null as skipped, preserves
          // drafts and returns the force-sync cooldown to the user.
          return null;
        } on StorageRotationUnconfirmedException catch (e) {
          Logger.warning('SDCardWalSync: $e — preserving drafts and deferring reconciliation; not rotating again');
          await _recoverStorageReplies(connection, 'rotation got no acknowledgement');
          return SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: [], isPartial: true);
        }
        // Returned normally = an ACK arrived, success or refusal alike.
        _noteStorageReplyHeard();
        if (rotated) break;
        Logger.warning('Rotation failed, retrying in 2 seconds...');
        await Future.delayed(const Duration(seconds: 2));
      }
      if (!rotated) throw Exception('Rotation failed');

      final wals = await _buildWalsFromFilesLocked(connection, dev.id);

      // Cancel is checked FIRST: a user who cancelled gets "did not run", and is not
      // charged the cooldown, whatever the listing was doing when they did it.
      if (_isCancelled) return null;

      if (wals == null) {
        await _recoverAfterFailedListing(connection);
        // The rotate DID land — the active bin is sealed and a fresh one started —
        // so this run reached the device whatever the listing then did. Returning
        // null would say the opposite: _runForcePipeline reads it as "nothing was
        // rotated", hands the cooldown back (licensing another rotate, and another
        // near-empty bin), and misses the isPartial branch that drops force mode —
        // so processing would finalize every draft on disk while the bin holding
        // their tail is still on the device. Partial says both true things at once:
        // we reached it, and we did not get everything.
        Logger.warning('SDCardWalSync: rotateAndSync rotated but the device did not answer '
            'CMD_LIST_FILES — reporting a partial sync');
        return SyncLocalFilesResponse(
          newConversationIds: [],
          updatedConversationIds: [],
          isPartial: true,
        );
      }

      return await _syncAllLocked(connection, dev.id, prefetchedWals: wals, progress: progress);
    } finally {
      _isSyncing = false;
      listener.onSyncFinished();
      _completeCancelIfPending();
      connection.releaseStorageLock();
    }
  }

  @override
  Future<void> deleteAllPendingWals() async {
    if (_device == null) return;
    final connection = await ServiceManager.instance().device.ensureConnection(
          _device!.id,
        );
    if (connection == null) return;

    if (connection.isStorageBusy) {
      Logger.debug('Storage busy, skipping: deleteAllPendingWals');
      return;
    }

    await connection.acquireStorageLock('deleteAllPendingWals');
    try {
      Logger.debug('SDCardWalSync: deleteAllPendingWals — Sending CMD_CLEAR_STORAGE (0x14)');
      final success = await connection.performClearStorage();
      if (success) {
        _wals = [];
        _listedOn = null;
        listener.onWalUpdated();
      } else {
        Logger.error('SDCardWalSync: CMD_CLEAR_STORAGE failed, falling back to per-file deletion');
        // No answer leaves nothing to delete this pass; the caller re-runs.
        final files = (await connection.listFiles())?.files ?? const <StorageFile>[];
        for (final file in files) {
          if (_isCancelled) break;
          await Future.delayed(const Duration(milliseconds: 5)); // Prevent UI starvation
          await connection.deleteFile(file);
          _wals.removeWhere(
            (w) => w.fileNum == file.index && w.storage == WalStorage.sdcard,
          );
        }
        listener.onWalUpdated();
      }
    } finally {
      connection.releaseStorageLock();
    }
  }
}
