enum WalStorage {
  local,
  sdcard,
}

enum WalStatus {
  miss,
  syncing,
  synced,
}

class Wal {
  final String device;
  final int fileNum;
  int walOffset;
  final int storageTotalBytes;
  final int timerStart;
  final int? sessionId;
  WalStorage storage;

  WalStatus status;
  bool isSyncing;
  // Consecutive sync attempts that failed for a reason of the file's own (a short read,
  // a lost packet, a read error) without moving it any further. Orders retries: a file
  // that keeps failing goes after the rest. Reset by progress and by a full transfer.
  int syncFailCount;
  // When the file first failed for a reason of its own — not a dropped link or a cancel.
  // Kept, and not moved by progress, until the file is received. Processing stops
  // waiting for the file [SDCardWalSyncImpl.heldBackGiveUpAfter] after it, or sooner
  // after [SDCardWalSyncImpl.heldBackGiveUpFailures] failed syncs in a row.
  int? failingSinceMs;
  // 0 includes legacy native prefixes that may contain synthesized gap bytes.
  // 1 is written only after starting a fresh contiguous native download.
  int nativeIntegrityVersion;
  // Accepted offset of the most recent native storage-integrity gap. A second gap at
  // the same offset means the same packet was lost again; the next resume then starts
  // earlier so the device cuts packets on different boundaries.
  int? lastIntegrityGapOffset;
  DateTime? syncStartedAt;

  Wal({
    required this.device,
    required this.fileNum,
    required this.walOffset,
    required this.storageTotalBytes,
    required this.timerStart,
    required this.storage,
    this.sessionId,
    this.status = WalStatus.miss,
    this.isSyncing = false,
    this.syncFailCount = 0,
    this.failingSinceMs,
    this.nativeIntegrityVersion = 0,
    this.lastIntegrityGapOffset,
  });

  // id is stable: keyed on timerStart (the file's Unix timestamp from firmware) so it
  // survives array-index shifts when earlier files are deleted between reconnects.
  // fileNum shifts after deletions but timerStart does not — matching on fileNum caused
  // partial-resume bookmarks to be applied to the wrong file after a disconnect mid-sync.
  // Falls back to fileNum for the rare case where timerStart is 0 (legacy persisted data).
  String get id => timerStart > 0 ? '$device-$timerStart' : '$device-$fileNum';

  String getSegmentFileNameByTimestamp(int timerStart, {int? sessionId}) {
    if (sessionId != null) {
      return '${timerStart}_$sessionId.bin';
    }
    return '${timerStart}_0.bin';
  }

  String getFileName() {
    return getSegmentFileNameByTimestamp(timerStart, sessionId: sessionId);
  }

  /// True while the device advertised more bytes for this file than have landed
  /// in the local bin — i.e. the transfer is mid-flight or ended short and the
  /// completeness guard left it `miss` for a resumed read on the next sync.
  ///
  /// The bin on disk is a PREFIX of the real recording, so it must not be
  /// decoded or pruned: the processing pass deletes every bin it consumes, and
  /// a deleted bin makes the resume append the tail to an empty file. Mirrors
  /// the guard's condition in SDCardWalSyncImpl._syncAllLocked.
  bool get isIncompleteTransfer => storageTotalBytes > 0 && walOffset < storageTotalBytes;

  /// Path of this WAL's bin relative to `raw_segments/`, matching the folder
  /// rule the download path uses (pre-time-sync files land under
  /// `session_<sessionId>/`). Same shape as the keys in
  /// [RecordingsManager.discardedRelBinPaths].
  String get relativeBinPath {
    final folder = timerStart < 946684800 ? 'session_$sessionId' : '$timerStart';
    return '$folder/${getFileName()}';
  }

  Map<String, dynamic> toJson() {
    return {
      'device': device,
      'fileNum': fileNum,
      'storageOffset': walOffset,
      'storageTotalBytes': storageTotalBytes,
      'timerStart': timerStart,
      'sessionId': sessionId,
      'storage': storage.name,
      'status': status.name,
      'syncFailCount': syncFailCount,
      'failingSinceMs': failingSinceMs,
      'nativeIntegrityVersion': nativeIntegrityVersion,
      'lastIntegrityGapOffset': lastIntegrityGapOffset,
    };
  }

  static List<Wal> fromJsonList(List<dynamic> jsonList) {
    return jsonList.map((j) => Wal.fromJson(j)).toList();
  }

  factory Wal.fromJson(Map<String, dynamic> json) {
    return Wal(
      device: json['device'] ?? '',
      fileNum: json['fileNum'] ?? 0,
      walOffset: json['storageOffset'] ?? 0,
      storageTotalBytes: json['storageTotalBytes'] ?? 0,
      timerStart: json['timerStart'] ?? 0,
      sessionId: json['sessionId'],
      storage: WalStorage.values.firstWhere((e) => e.name == json['storage'], orElse: () => WalStorage.local),
      status: WalStatus.values.firstWhere((e) => e.name == json['status'], orElse: () => WalStatus.miss),
      syncFailCount: json['syncFailCount'] ?? 0,
      failingSinceMs: json['failingSinceMs'],
      nativeIntegrityVersion: json['nativeIntegrityVersion'] ?? 0,
      lastIntegrityGapOffset: json['lastIntegrityGapOffset'],
    );
  }
}
