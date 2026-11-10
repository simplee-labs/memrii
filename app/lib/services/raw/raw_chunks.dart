// Sealed raw audio: each Omi file kept on the phone as read-only chunks.
//
// RECORDINGS_PIPELINE_REDESIGN.md §1 (memrii-private docs). A download writes into a
// private part file; when the transfer stops, what arrived is sealed into a chunk that
// nothing writes again. A device file's logical file is its chunks in offset order, and
// every offset outside this file is logical. Only part files are ever cut: a reader can
// never see bytes change under it.
//
// Not switched on yet. The current pipeline reads every `.bin` as a whole file and cannot
// read continuation chunks, so downloads keep writing whole bins until the new pipeline
// replaces it (step 6). Until then this runs only in tests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omi/utils/atomic_file.dart';
import 'package:omi/utils/logger.dart';

/// How far a chunk's bytes are known to be the Omi's. Recorded when the chunk is
/// sealed, never inferred later.
enum ChunkProvenance {
  /// Native receiver, integrity format, and the firmware echoed the requested timestamp.
  echoed,

  /// Native receiver and integrity format, but nothing correlated the read with the file:
  /// an older two-byte ACK, or a part sealed after a crash, whose ACK is unknown.
  uncorrelated,

  /// On the phone before this format existed: `wals.json` cannot say how it was read.
  imported,

  /// Written by the Dart fallback receiver, which can leave holes.
  unverified,
}

/// Where a device file stands. Only a terminal state lets the phone's copy be final.
enum SourceLifecycle {
  /// More of it may still arrive. A hole waived by the planner stays here: waiving
  /// changes what is interpreted, not whether the rest will be downloaded.
  receiving,

  /// The phone has as many bytes as the Omi advertised.
  complete,

  /// A later listing shows the Omi's copy shorter than the phone's (mount recovery can
  /// shorten its newest closed segment); the phone's longer copy stands.
  shortenedAtSource,

  /// The file left the Omi before it completed; what arrived is all there is.
  sourceGone;

  bool get isTerminal => this != receiving;
}

/// One device file's identity and where its chunks live under `raw_segments/`, laid out
/// exactly as today's whole bins: `<timerStart>/<timerStart>_<session>.bin`, or
/// `session_<session>/…` before the Omi's clock was set.
class RawFileKey {
  final int timerStart;
  final int? sessionId;

  const RawFileKey(this.timerStart, this.sessionId);

  /// The download path's folder rule (SDCardWalSync), unchanged.
  String get folder => timerStart < 946684800 ? 'session_$sessionId' : '$timerStart';

  String get stem => '${timerStart}_${sessionId ?? 0}';

  /// The first chunk's name: today's bin name, so a file that arrives in one transfer
  /// looks exactly as it does now.
  String chunkName(int offset) => offset == 0 ? '$stem.bin' : '$stem@$offset.bin';

  String partName(int offset) => '${chunkName(offset)}.partial';

  String get manifestName => '$stem.chunks.json';

  /// `<folder>/<stem>.bin`, the relative path every other part of the app names a raw
  /// file by.
  String get rel => '$folder/${chunkName(0)}';

  /// The key a [rel] path names, or null when it is not a raw file's.
  static RawFileKey? fromRel(String rel) {
    final parts = rel.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) return null;
    final m = RegExp(r'^(\d+)_(\d+)\.bin$').firstMatch(parts.last);
    if (m == null) return null;
    final folder = parts[parts.length - 2];
    return RawFileKey(int.parse(m.group(1)!), folder == 'session_null' ? null : int.parse(m.group(2)!));
  }

  @override
  bool operator ==(Object other) =>
      other is RawFileKey && other.timerStart == timerStart && other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(timerStart, sessionId);

  @override
  String toString() => rel;
}

class RawChunk {
  final int offset;
  final int length;
  final ChunkProvenance provenance;
  final String path;

  const RawChunk({required this.offset, required this.length, required this.provenance, required this.path});

  int get end => offset + length;
}

/// A device file as the phone holds it: its sealed chunks, contiguous from 0.
class LogicalRawFile {
  final RawFileKey key;
  final List<RawChunk> chunks;
  final SourceLifecycle lifecycle;

  /// The length the Omi listed, once known.
  final int? advertisedLength;

  /// When the first chunk was sealed. Recorded once: it is the fallback time anchor for
  /// a file the Omi could not date, so it must not move when a file is copied.
  final int? firstSealedAtMs;

  /// False for a bin that predates this format: one chunk, provenance [ChunkProvenance.imported].
  final bool hasManifest;

  const LogicalRawFile({
    required this.key,
    required this.chunks,
    required this.lifecycle,
    required this.advertisedLength,
    required this.firstSealedAtMs,
    required this.hasManifest,
  });

  int get length => chunks.isEmpty ? 0 : chunks.last.end;

  /// The logical bytes [start, end), read across chunks.
  Future<Uint8List> read(int start, int end) async {
    if (start < 0 || end > length || start > end) {
      throw RangeError('[$start, $end) is outside ${key.rel}, which holds $length bytes');
    }
    final out = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      if (chunk.end <= start || chunk.offset >= end) continue;
      final from = (start > chunk.offset ? start : chunk.offset) - chunk.offset;
      final to = (end < chunk.end ? end : chunk.end) - chunk.offset;
      final raf = await File(chunk.path).open();
      try {
        await raf.setPosition(from);
        out.add(await raf.read(to - from));
      } finally {
        await raf.close();
      }
    }
    final bytes = out.takeBytes();
    if (bytes.length != end - start) {
      throw StateError('${key.rel}: read ${bytes.length} of ${end - start} bytes; a chunk is shorter than recorded');
    }
    return bytes;
  }
}

/// A logical file whose manifest and chunks disagree in a way sealing cannot produce.
class RawFileInconsistent implements Exception {
  final String message;
  RawFileInconsistent(this.message);
  @override
  String toString() => 'RawFileInconsistent: $message';
}

/// Seals parts into chunks and keeps each logical file's manifest.
///
/// The manifest (`<stem>.chunks.json`, rewritten whole with [AtomicFile]) is written
/// before the part is renamed, so a crash between the two leaves the chunk listed with
/// its part still in place, and [recover] finishes the rename. A reader that loads in
/// that window simply sees the file end before it.
class RawChunkStore {
  /// The sealed layout is off until the new pipeline can read it (step 6).
  static bool enabled = false;

  final String documentsPath;

  RawChunkStore(this.documentsPath);

  static final Map<String, Future<void>> _manifestLocks = {};

  Directory folderOf(RawFileKey key) => Directory('$documentsPath/raw_segments/${key.folder}');

  File partFile(RawFileKey key, int appendOffset) => File('${folderOf(key).path}/${key.partName(appendOffset)}');

  File _chunkFile(RawFileKey key, int offset) => File('${folderOf(key).path}/${key.chunkName(offset)}');

  File _manifestFile(RawFileKey key) => File('${folderOf(key).path}/${key.manifestName}');

  /// The file as sealed so far. A bin with no manifest predates this format and is one
  /// imported chunk; a missing file is empty.
  Future<LogicalRawFile> load(RawFileKey key) async {
    final manifest = await _readManifest(key);
    if (manifest == null) {
      final first = _chunkFile(key, 0);
      final exists = await first.exists();
      return LogicalRawFile(
        key: key,
        chunks: exists
            ? [
                RawChunk(
                    offset: 0, length: await first.length(), provenance: ChunkProvenance.imported, path: first.path)
              ]
            : const [],
        lifecycle: SourceLifecycle.receiving,
        advertisedLength: null,
        firstSealedAtMs: null,
        hasManifest: false,
      );
    }
    final chunks = <RawChunk>[];
    var end = 0;
    for (final entry in manifest.chunks) {
      if (entry.offset != end) {
        throw RawFileInconsistent('${key.rel}: chunk at ${entry.offset} after $end bytes');
      }
      final file = _chunkFile(key, entry.offset);
      if (!await file.exists()) {
        // Listed but not yet renamed from its part: sealing is in progress, or a crash
        // interrupted it and recover() has not run. The file ends before it.
        if (await partFile(key, entry.offset).exists()) break;
        throw RawFileInconsistent('${key.rel}: chunk at ${entry.offset} is missing');
      }
      final length = await file.length();
      if (length != entry.length) {
        throw RawFileInconsistent('${key.rel}: chunk at ${entry.offset} holds $length bytes, not ${entry.length}');
      }
      chunks.add(RawChunk(offset: entry.offset, length: entry.length, provenance: entry.provenance, path: file.path));
      end += entry.length;
    }
    return LogicalRawFile(
      key: key,
      chunks: chunks,
      lifecycle: manifest.lifecycle,
      advertisedLength: manifest.advertisedLength,
      firstSealedAtMs: manifest.firstSealedAtMs,
      hasManifest: true,
    );
  }

  /// Seals the part that a transfer starting at logical [appendOffset] wrote, keeping its
  /// first [keepLength] bytes: the bytes the receiver accepted. Anything after them is
  /// cut off first (nobody has read a part). Returns the chunk, or null when nothing is
  /// kept, in which case the part is deleted.
  Future<RawChunk?> seal(
    RawFileKey key, {
    required int appendOffset,
    required int keepLength,
    required ChunkProvenance provenance,
    int? advertisedLength,
  }) =>
      _locked(
          key,
          () => _seal(key,
              appendOffset: appendOffset,
              keepLength: keepLength,
              provenance: provenance,
              advertisedLength: advertisedLength));

  Future<RawChunk?> _seal(
    RawFileKey key, {
    required int appendOffset,
    required int keepLength,
    required ChunkProvenance provenance,
    required int? advertisedLength,
  }) async {
    final part = partFile(key, appendOffset);
    if (!await part.exists()) {
      if (keepLength > 0) throw RawFileInconsistent('${key.rel}: no part at $appendOffset to seal');
      return null;
    }
    final sealed = await load(key);
    if (sealed.length != appendOffset) {
      throw RawFileInconsistent('${key.rel}: part at $appendOffset, but the file ends at ${sealed.length}');
    }
    final partLength = await part.length();
    final keep = keepLength < 0 ? 0 : (keepLength < partLength ? keepLength : partLength);
    if (keep == 0) {
      if (partLength > 0) {
        Logger.debug('RawChunkStore: ${key.rel}: none of the $partLength byte(s) at $appendOffset was accepted');
      }
      await part.delete();
      if (advertisedLength != null) await _updateManifest(key, (m) => m.advertisedLength ??= advertisedLength);
      return null;
    }
    final raf = await part.open(mode: FileMode.append);
    try {
      if (partLength > keep) await raf.truncate(keep);
      await raf.flush();
    } finally {
      await raf.close();
    }
    final chunk = _chunkFile(key, appendOffset);
    if (await chunk.exists()) throw RawFileInconsistent('${key.rel}: chunk at $appendOffset already sealed');
    await _updateManifest(key, (m) {
      m.chunks.add(_ManifestChunk(appendOffset, keep, provenance));
      m.firstSealedAtMs ??= DateTime.now().millisecondsSinceEpoch;
      m.advertisedLength ??= advertisedLength;
    });
    await part.rename(chunk.path);
    Logger.debug('RawChunkStore: ${key.rel}: sealed [$appendOffset,${appendOffset + keep}) (${provenance.name})'
        '${partLength > keep ? ', ${partLength - keep} unaccepted byte(s) cut' : ''}');
    return RawChunk(offset: appendOffset, length: keep, provenance: provenance, path: chunk.path);
  }

  /// Every logical file with a chunk, a manifest or a first part under `raw_segments/`:
  /// a file whose first transfer is still running is a logical file too.
  Future<Set<RawFileKey>> listKeys() async {
    final root = Directory('$documentsPath/raw_segments');
    final keys = <RawFileKey>{};
    if (!await root.exists()) return keys;
    await for (final folder in root.list(followLinks: false)) {
      if (folder is! Directory) continue;
      final name = folder.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      await for (final e in folder.list(followLinks: false)) {
        if (e is! File) continue;
        final m = RegExp(r'^(\d+_\d+)(?:\.bin|\.chunks\.json|\.bin\.partial)$').firstMatch(e.uri.pathSegments.last);
        if (m == null) continue;
        final key = RawFileKey.fromRel('$name/${m.group(1)}.bin');
        if (key != null) keys.add(key);
      }
    }
    return keys;
  }

  /// Deletes everything of [key] on the phone: its chunks, manifest, card, parts and kept
  /// conflicts, and its folder once empty. Only the gate (§6) and the debug reset call
  /// this; it is idempotent.
  Future<void> deleteLogicalFile(RawFileKey key) => _locked(key, () async {
        final folder = folderOf(key);
        if (!await folder.exists()) return;
        await for (final e in folder.list(followLinks: false)) {
          final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
          if (e is File && (name.startsWith('${key.stem}.') || name.startsWith('${key.stem}@'))) await e.delete();
        }
        if (await folder.list().isEmpty) await folder.delete();
      });

  /// Records where the device file stands. A terminal state is final; the advertised
  /// length is set once. [SourceLifecycle.complete] needs every advertised byte sealed:
  /// a clean end of transfer alone is not completion.
  Future<void> setLifecycle(RawFileKey key, SourceLifecycle lifecycle, {int? advertisedLength}) =>
      _locked(key, () async {
        if (lifecycle == SourceLifecycle.complete) {
          final file = await load(key);
          final advertised = file.advertisedLength ?? advertisedLength;
          if (advertised == null || file.length < advertised) {
            throw RawFileInconsistent('${key.rel}: ${file.length} of ${advertised ?? 'unknown'} bytes sealed, '
                'not complete');
          }
        }
        await _updateManifest(key, (m) {
          if (m.lifecycle.isTerminal && m.lifecycle != lifecycle) {
            throw RawFileInconsistent('${key.rel}: already ${m.lifecycle.name}, cannot become ${lifecycle.name}');
          }
          if (m.lifecycle != lifecycle) {
            Logger.debug('RawChunkStore: ${key.rel}: ${m.lifecycle.name} -> ${lifecycle.name}'
                '${advertisedLength == null ? '' : ', $advertisedLength bytes listed'}');
          }
          m.lifecycle = lifecycle;
          m.advertisedLength ??= advertisedLength;
        });
      });

  /// Run once at startup, before any download starts: finishes seals a crash interrupted
  /// and seals parts a crash left behind. A leftover part keeps only the bytes before
  /// [persistedEnd] (the logical progress last saved for its file); with none saved, it
  /// keeps nothing and those bytes are fetched again. Returns the files it changed.
  ///
  /// A sealed chunk is never replaced. A part at an offset already sealed is a stray (a
  /// transfer that could not seal); it is deleted only when the chunk already holds every
  /// byte of it, and otherwise kept aside as a conflict, never over an earlier one.
  Future<Set<RawFileKey>> recover({required int? Function(RawFileKey key) persistedEnd}) async {
    final root = Directory('$documentsPath/raw_segments');
    if (!await root.exists()) return {};
    final parts = [
      await for (final entity in root.list(recursive: true))
        if (entity is File && entity.path.endsWith('.bin.partial')) entity
    ];
    final changed = <RawFileKey>{};
    for (final part in parts) {
      final parsed = _parsePartName(part.uri.pathSegments.last, part.parent.uri.pathSegments);
      if (parsed == null) continue;
      final (key, offset) = parsed;
      await _locked(key, () async {
        final chunk = _chunkFile(key, offset);
        final listed = (await _readManifest(key))?.chunks.where((c) => c.offset == offset).firstOrNull;
        if (await chunk.exists()) {
          await _setAsideStray(key, part, chunk);
        } else if (listed != null) {
          // Listed before a crash stopped the rename: finish it, exactly as recorded.
          final raf = await part.open(mode: FileMode.append);
          try {
            if (await raf.length() < listed.length) {
              throw RawFileInconsistent('${key.rel}: part at $offset is shorter than its listed chunk');
            }
            await raf.truncate(listed.length);
            await raf.flush();
          } finally {
            await raf.close();
          }
          await part.rename(chunk.path);
          Logger.debug('RawChunkStore: ${key.rel}: finished sealing the chunk at $offset that a crash interrupted');
        } else if ((await load(key)).length != offset) {
          // Not where the sealed chunks end, so no transfer can have been writing it last.
          await _setAsideStray(key, part, null);
        } else {
          final end = persistedEnd(key);
          Logger.debug('RawChunkStore: ${key.rel}: a crash left a part at $offset; '
              '${end == null ? 'no progress was saved, so it is fetched again' : 'keeping what precedes $end'}');
          await _seal(key,
              appendOffset: offset,
              keepLength: end == null ? 0 : end - offset,
              provenance: ChunkProvenance.uncorrelated,
              advertisedLength: null);
        }
      });
      changed.add(key);
    }
    return changed;
  }

  Future<void> _setAsideStray(RawFileKey key, File part, File? chunk) async {
    final bytes = await part.readAsBytes();
    if (chunk != null && _startsWith(await chunk.readAsBytes(), bytes)) {
      await part.delete();
      Logger.debug('RawChunkStore: ${key.rel}: removed a stray part the sealed chunk already holds');
      return;
    }
    // Kept for diagnosis, under a name nothing reads, never over an earlier conflict; one
    // byte-identical to an earlier conflict adds nothing and is removed.
    for (var n = 0;; n++) {
      final target = File(n == 0 ? '${part.path}.conflict' : '${part.path}.conflict.$n');
      if (!await target.exists()) {
        await part.rename(target.path);
        Logger.error('RawChunkStore: ${key.rel}: a stray part is not in the sealed copy; kept as ${target.path}');
        return;
      }
      final earlier = await target.readAsBytes();
      if (earlier.length == bytes.length && _startsWith(earlier, bytes)) {
        await part.delete();
        return;
      }
    }
  }

  /// Whether [whole] begins with every byte of [prefix].
  static bool _startsWith(List<int> whole, List<int> prefix) {
    if (prefix.length > whole.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (whole[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Parses `<stem>.bin.partial` / `<stem>@<offset>.bin.partial` in its folder.
  (RawFileKey, int)? _parsePartName(String name, List<String> parentSegments) {
    final match = RegExp(r'^(\d+)_(\d+)(?:@(\d+))?\.bin\.partial$').firstMatch(name);
    if (match == null) return null;
    final timerStart = int.parse(match.group(1)!);
    final session = int.parse(match.group(2)!);
    final folder = parentSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
    // `session_null` holds files whose session was unknown; their stem says 0.
    final sessionId = folder == 'session_null' ? null : session;
    return (RawFileKey(timerStart, sessionId), int.parse(match.group(3) ?? '0'));
  }

  Future<T> _locked<T>(RawFileKey key, Future<T> Function() body) {
    final path = _manifestFile(key).path;
    final previous = _manifestLocks[path] ?? Future<void>.value();
    final result = previous.then((_) => body());
    final tail = result.then((_) {}, onError: (_) {});
    _manifestLocks[path] = tail;
    unawaited(tail.whenComplete(() {
      if (identical(_manifestLocks[path], tail)) _manifestLocks.remove(path);
    }));
    return result;
  }

  /// A file's first manifest. A bin from before this format is carried forward as its
  /// first, imported chunk, exactly as [load] reads it.
  Future<_Manifest> _firstManifest(RawFileKey key) async {
    final manifest = _Manifest.empty(key);
    final first = _chunkFile(key, 0);
    if (await first.exists()) manifest.chunks.add(_ManifestChunk(0, await first.length(), ChunkProvenance.imported));
    return manifest;
  }

  Future<_Manifest?> _readManifest(RawFileKey key) async {
    final file = _manifestFile(key);
    if (!await file.exists()) return null;
    return _Manifest.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  Future<void> _updateManifest(RawFileKey key, void Function(_Manifest m) change) async {
    final manifest = await _readManifest(key) ?? await _firstManifest(key);
    change(manifest);
    await folderOf(key).create(recursive: true);
    await AtomicFile.writeString(_manifestFile(key), jsonEncode(manifest.toJson()));
  }
}

class _ManifestChunk {
  final int offset;
  final int length;
  final ChunkProvenance provenance;
  _ManifestChunk(this.offset, this.length, this.provenance);
}

class _Manifest {
  final int timerStart;
  final int? sessionId;
  final List<_ManifestChunk> chunks;
  SourceLifecycle lifecycle;
  int? advertisedLength;
  int? firstSealedAtMs;

  _Manifest(this.timerStart, this.sessionId, this.chunks, this.lifecycle, this.advertisedLength, this.firstSealedAtMs);

  _Manifest.empty(RawFileKey key) : this(key.timerStart, key.sessionId, [], SourceLifecycle.receiving, null, null);

  static const version = 1;

  factory _Manifest.fromJson(Map<String, dynamic> j) {
    if (j['v'] != version) throw RawFileInconsistent('manifest version ${j['v']} is not $version');
    return _Manifest(
      j['timerStart'] as int,
      j['sessionId'] as int?,
      [
        for (final c in (j['chunks'] as List).cast<Map<String, dynamic>>())
          _ManifestChunk(
              c['offset'] as int, c['length'] as int, ChunkProvenance.values.byName(c['provenance'] as String))
      ],
      SourceLifecycle.values.byName(j['lifecycle'] as String),
      j['advertisedLength'] as int?,
      j['firstSealedAtMs'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'timerStart': timerStart,
        'sessionId': sessionId,
        'chunks': [
          for (final c in chunks) {'offset': c.offset, 'length': c.length, 'provenance': c.provenance.name}
        ],
        'lifecycle': lifecycle.name,
        'advertisedLength': advertisedLength,
        'firstSealedAtMs': firstSealedAtMs,
      };
}
