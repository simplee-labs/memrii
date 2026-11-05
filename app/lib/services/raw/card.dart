// A file's card: what one Omi file holds, read once (RECORDINGS_PIPELINE_REDESIGN.md §2).
//
// The parse stage (here) walks the records without decoding: every audio frame's offset
// and length, and every marker with its payload and its identity (the file and the
// marker's byte offset). The audio stage (card_audio.dart) adds, per frame, whether Opus
// could decode it and how likely it is speech. A card is a pure function of the file's
// bytes and the versions that made it; it decides nothing. Frame times, gaps, splits and
// what a marker means are the planner's (step 3).
//
// Not switched on yet (see raw_chunks.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/utils/atomic_file.dart';

/// Changes whenever the card's meaning or layout changes; an older card is rebuilt.
const int cardIndexerVersion = 1;

/// The largest Opus packet (RFC 6716). A length word above it cannot be an audio frame.
const int maxFramePayload = 1275;

/// The longest record the format has: a maximal frame with its length word and padding.
const int maxRecordBytes = 4 + ((maxFramePayload + 3) & ~3);

const int _header = 0xFFFFFFFB;
const int _tap = 0xFFFFFFFE;
const int _stop = 0xFFFFFFFC;
const int _resume = 0xFFFFFFFD;
const int _muteOn = 0xFFFFFFFA;
const int _muteOff = 0xFFFFFFF9;
const int _priorityStart = 0xFFFFFFF8;

const int _headerBytes = 36;
const int _markerBytes = 20;

/// Before this, a timestamp is the Omi's "clock not set" value, not a date.
const int minValidEpochMs = 946684800000;

enum CardEventKind {
  /// The 36-byte metadata header: start time, start uptime, IMU ticks, session.
  header,

  /// A button tap (0xFFFFFFFE).
  tap,

  /// A stop (0xFFFFFFFC): manual-mode stop, or the end of a Priority Recording.
  stop,

  /// A VAD resume (0xFFFFFFFD): the Omi woke from silence. Its time is in seconds.
  resume,

  /// Mute on (0xFFFFFFFA).
  muteOn,

  /// Mute off (0xFFFFFFF9).
  muteOff,

  /// Priority Recording start (0xFFFFFFF8).
  priorityStart,
}

/// One marker, read whole. Its identity is its file and byte offset.
class CardEvent {
  final CardEventKind kind;

  /// Logical byte offset of the record.
  final int offset;

  /// How many audio frames of the file precede it.
  final int frameIndex;

  /// Device wall clock in ms as the record carries it (a resume's seconds × 1000; a
  /// header's start). Below [minValidEpochMs] the clock was not set.
  final int utcMs;

  /// Device uptime in ms (a header's start uptime).
  final int uptimeMs;

  /// The session the record names; a resume names none.
  final int? sessionId;

  /// A header's IMU tick count.
  final int? imuTicks;

  const CardEvent({
    required this.kind,
    required this.offset,
    required this.frameIndex,
    required this.utcMs,
    required this.uptimeMs,
    this.sessionId,
    this.imuTicks,
  });

  bool get hasClock => utcMs > minValidEpochMs;

  Map<String, Object?> toJson() => {
        'k': kind.name,
        'o': offset,
        'f': frameIndex,
        'u': utcMs,
        'up': uptimeMs,
        if (sessionId != null) 's': sessionId,
        if (imuTicks != null) 'i': imuTicks,
      };

  factory CardEvent.fromJson(Map<String, Object?> j) => CardEvent(
        kind: CardEventKind.values.byName(j['k']! as String),
        offset: j['o']! as int,
        frameIndex: j['f']! as int,
        utcMs: j['u']! as int,
        uptimeMs: j['up']! as int,
        sessionId: j['s'] as int?,
        imuTicks: j['i'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is CardEvent &&
      other.kind == kind &&
      other.offset == offset &&
      other.frameIndex == frameIndex &&
      other.utcMs == utcMs &&
      other.uptimeMs == uptimeMs &&
      other.sessionId == sessionId &&
      other.imuTicks == imuTicks;

  @override
  int get hashCode => Object.hash(kind, offset, frameIndex, utcMs, uptimeMs, sessionId, imuTicks);

  @override
  String toString() => '${kind.name}@$offset(frame $frameIndex)';
}

/// Why the parse stopped before the end of the bytes.
enum ParseStop {
  /// It reached the end on a record boundary.
  none,

  /// The last record is not all there.
  incomplete,

  /// A length word that is neither a marker nor a possible frame.
  unknownRecord,
}

/// How a file's bytes end, once its lifecycle is known.
enum FileEnd {
  /// Every byte is in a whole record.
  clean,

  /// Still downloading: the rest of the last record has not arrived.
  awaitingBytes,

  /// Complete, ending in less than one record: a cut last record, skipped.
  cutTail,

  /// Complete, and unreadable from [ParsedRecords.parsedEnd] on with more than a record
  /// left: the file is damaged there.
  damaged,
}

/// The parse stage's result.
class ParsedRecords {
  /// Logical offset of each audio frame's length word, in order.
  final Uint32List frameOffsets;

  /// Each audio frame's payload length.
  final Uint16List frameLengths;

  final List<CardEvent> events;

  /// The boundary after the last whole record.
  final int parsedEnd;

  /// The bytes parsed.
  final int length;

  final ParseStop stop;

  const ParsedRecords({
    required this.frameOffsets,
    required this.frameLengths,
    required this.events,
    required this.parsedEnd,
    required this.length,
    required this.stop,
  });

  int get frameCount => frameOffsets.length;

  /// The metadata header at the file's start, the one that dates it.
  CardEvent? get header =>
      events.isNotEmpty && events.first.kind == CardEventKind.header && events.first.offset == 0 ? events.first : null;

  /// How the bytes end for a file in [lifecycle]: only a terminal file can have a final,
  /// unreadable remainder; a file still receiving is waiting for bytes.
  FileEnd endFor(SourceLifecycle lifecycle) {
    if (parsedEnd == length) return FileEnd.clean;
    if (!lifecycle.isTerminal) return stop == ParseStop.unknownRecord ? FileEnd.damaged : FileEnd.awaitingBytes;
    return stop == ParseStop.incomplete && length - parsedEnd < maxRecordBytes ? FileEnd.cutTail : FileEnd.damaged;
  }
}

/// Walks [bytes], a logical file's bytes from offset 0, record by record, exactly as the
/// firmware writes them: a 4-byte word that is padding (0 or 0xFFFFFFFF), a marker tag,
/// or the payload length of an audio frame whose record is padded to 4 bytes. A record
/// counts only when it is all there, padding included.
ParsedRecords parseRecords(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final length = bytes.length;
  final offsets = <int>[];
  final lengths = <int>[];
  final events = <CardEvent>[];
  var offset = 0;
  var stop = ParseStop.none;

  CardEvent marker(CardEventKind kind) => CardEvent(
        kind: kind,
        offset: offset,
        frameIndex: offsets.length,
        utcMs: data.getUint64(offset + 4, Endian.little),
        uptimeMs: data.getUint32(offset + 12, Endian.little),
        sessionId: data.getUint32(offset + 16, Endian.little),
      );

  while (offset < length) {
    if (offset + 4 > length) {
      stop = ParseStop.incomplete;
      break;
    }
    final word = data.getUint32(offset, Endian.little);
    if (word == 0 || word == 0xFFFFFFFF) {
      offset += 4;
      continue;
    }
    final size = switch (word) {
      _header => _headerBytes,
      _tap || _stop || _resume || _muteOn || _muteOff || _priorityStart => _markerBytes,
      _ when word <= maxFramePayload => 4 + ((word + 3) & ~3),
      _ => -1,
    };
    if (size < 0) {
      stop = ParseStop.unknownRecord;
      break;
    }
    if (offset + size > length) {
      stop = ParseStop.incomplete;
      break;
    }
    switch (word) {
      case _header:
        events.add(CardEvent(
          kind: CardEventKind.header,
          offset: offset,
          frameIndex: offsets.length,
          utcMs: data.getUint64(offset + 8, Endian.little),
          uptimeMs: data.getUint64(offset + 16, Endian.little),
          imuTicks: data.getUint32(offset + 24, Endian.little),
          sessionId: data.getUint32(offset + 28, Endian.little),
        ));
      case _resume:
        events.add(CardEvent(
          kind: CardEventKind.resume,
          offset: offset,
          frameIndex: offsets.length,
          utcMs: data.getUint32(offset + 4, Endian.little) * 1000,
          uptimeMs: data.getUint32(offset + 8, Endian.little),
        ));
      case _tap:
        events.add(marker(CardEventKind.tap));
      case _stop:
        events.add(marker(CardEventKind.stop));
      case _muteOn:
        events.add(marker(CardEventKind.muteOn));
      case _muteOff:
        events.add(marker(CardEventKind.muteOff));
      case _priorityStart:
        events.add(marker(CardEventKind.priorityStart));
      default:
        offsets.add(offset);
        lengths.add(word);
    }
    offset += size;
  }
  return ParsedRecords(
    frameOffsets: Uint32List.fromList(offsets),
    frameLengths: Uint16List.fromList(lengths),
    events: events,
    parsedEnd: offset,
    length: length,
    stop: stop,
  );
}

/// What the audio stage found, per frame.
class FrameAudio {
  /// 1 where Opus decoded the frame, 0 where it could not.
  final Uint8List decoded;

  /// The highest speech probability among the VAD windows that completed during the
  /// frame, or a negative value where none did (or the card has no VAD).
  final Float32List speech;

  const FrameAudio({required this.decoded, required this.speech});
}

/// A file's card.
class FileCard {
  final RawFileKey key;
  final int indexerVersion;

  /// The chunks it was built from, as (offset, length): a file that has grown since has a
  /// stale card.
  final List<(int, int)> chunks;

  final ParsedRecords records;

  /// The Opus decoder and VAD model that produced [audio]; [noVad] when the device runs
  /// without Silero, which makes every decoded frame speech for the planner (AAD rules).
  final String decoderId;
  final String vadModelId;
  final FrameAudio audio;

  static const noVad = 'none';

  const FileCard({
    required this.key,
    required this.indexerVersion,
    required this.chunks,
    required this.records,
    required this.decoderId,
    required this.vadModelId,
    required this.audio,
  });

  bool get hasVad => vadModelId != noVad;

  /// Whether this card still describes [file] as built by these versions.
  bool isCurrentFor(LogicalRawFile file, {required String decoderId, required String vadModelId}) =>
      key == file.key &&
      indexerVersion == cardIndexerVersion &&
      this.decoderId == decoderId &&
      this.vadModelId == vadModelId &&
      _sameChunks(file.chunks.map((c) => (c.offset, c.length)).toList());

  bool _sameChunks(List<(int, int)> other) {
    if (other.length != chunks.length) return false;
    for (var i = 0; i < chunks.length; i++) {
      if (other[i] != chunks[i]) return false;
    }
    return true;
  }

  EventSummary get summary => EventSummary(
        key: key,
        length: records.length,
        frameCount: records.frameCount,
        firstFrameOffset: records.frameCount == 0 ? null : records.frameOffsets[0],
        events: records.events,
        hasVad: hasVad,
      );

  static const _magic = 0x4452434D; // "MCRD"

  /// Binary layout: magic, a JSON head (identity, versions, events, parse end), then the
  /// per-frame arrays, each 4-byte aligned.
  Uint8List encode() {
    final head = utf8.encode(jsonEncode({
      'timerStart': key.timerStart,
      'sessionId': key.sessionId,
      'indexerVersion': indexerVersion,
      'chunks': [
        for (final (o, l) in chunks) [o, l]
      ],
      'decoderId': decoderId,
      'vadModelId': vadModelId,
      'length': records.length,
      'parsedEnd': records.parsedEnd,
      'stop': records.stop.name,
      'events': [for (final e in records.events) e.toJson()],
      'frames': records.frameCount,
    }));
    final n = records.frameCount;
    final headPadded = (head.length + 3) & ~3;
    final lengthsBytes = (n * 2 + 3) & ~3;
    final decodedBytes = (n + 3) & ~3;
    final out = ByteData(8 + headPadded + n * 4 + lengthsBytes + decodedBytes + n * 4);
    out.setUint32(0, _magic, Endian.little);
    out.setUint32(4, head.length, Endian.little);
    final bytes = out.buffer.asUint8List();
    bytes.setRange(8, 8 + head.length, head);
    var at = 8 + headPadded;
    for (var i = 0; i < n; i++, at += 4) {
      out.setUint32(at, records.frameOffsets[i], Endian.little);
    }
    for (var i = 0; i < n; i++) {
      out.setUint16(at + i * 2, records.frameLengths[i], Endian.little);
    }
    at += lengthsBytes;
    bytes.setRange(at, at + n, audio.decoded);
    at += decodedBytes;
    for (var i = 0; i < n; i++, at += 4) {
      out.setFloat32(at, audio.speech[i], Endian.little);
    }
    return bytes;
  }

  static FileCard decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 8 || data.getUint32(0, Endian.little) != _magic) {
      throw const FormatException('not a card');
    }
    final headLength = data.getUint32(4, Endian.little);
    final head = jsonDecode(utf8.decode(bytes.sublist(8, 8 + headLength))) as Map<String, Object?>;
    final n = head['frames']! as int;
    var at = 8 + ((headLength + 3) & ~3);
    final offsets = Uint32List(n);
    for (var i = 0; i < n; i++, at += 4) {
      offsets[i] = data.getUint32(at, Endian.little);
    }
    final lengths = Uint16List(n);
    for (var i = 0; i < n; i++) {
      lengths[i] = data.getUint16(at + i * 2, Endian.little);
    }
    at += (n * 2 + 3) & ~3;
    final decoded = Uint8List.fromList(bytes.sublist(at, at + n));
    at += (n + 3) & ~3;
    final speech = Float32List(n);
    for (var i = 0; i < n; i++, at += 4) {
      speech[i] = data.getFloat32(at, Endian.little);
    }
    if (at != bytes.length) throw const FormatException('card length does not match its frame count');
    return FileCard(
      key: RawFileKey(head['timerStart']! as int, head['sessionId'] as int?),
      indexerVersion: head['indexerVersion']! as int,
      chunks: [for (final c in (head['chunks']! as List).cast<List<Object?>>()) (c[0]! as int, c[1]! as int)],
      records: ParsedRecords(
        frameOffsets: offsets,
        frameLengths: lengths,
        events: [for (final e in (head['events']! as List).cast<Map<String, Object?>>()) CardEvent.fromJson(e)],
        parsedEnd: head['parsedEnd']! as int,
        length: head['length']! as int,
        stop: ParseStop.values.byName(head['stop']! as String),
      ),
      decoderId: head['decoderId']! as String,
      vadModelId: head['vadModelId']! as String,
      audio: FrameAudio(decoded: decoded, speech: speech),
    );
  }
}

/// What a file contributes to the planner's event layer, kept in the ledger after the
/// raw file is gone: its identity and every marker, with no per-frame data.
class EventSummary {
  final RawFileKey key;
  final int length;
  final int frameCount;

  /// Where the first frame is, if any: what a released file's audio wall is placed at.
  final int? firstFrameOffset;
  final List<CardEvent> events;

  /// Whether the card was made with the VAD model: the planner's flood guard, an event
  /// rule, applies only without it, so a receipt keeps it.
  final bool hasVad;

  const EventSummary({
    required this.key,
    required this.length,
    required this.frameCount,
    required this.firstFrameOffset,
    required this.events,
    required this.hasVad,
  });

  Map<String, Object?> toJson() => {
        'timerStart': key.timerStart,
        'sessionId': key.sessionId,
        'length': length,
        'frames': frameCount,
        if (firstFrameOffset != null) 'firstFrame': firstFrameOffset,
        'events': [for (final e in events) e.toJson()],
        'vad': hasVad,
      };

  factory EventSummary.fromJson(Map<String, Object?> j) => EventSummary(
        key: RawFileKey(j['timerStart']! as int, j['sessionId'] as int?),
        length: j['length']! as int,
        frameCount: j['frames']! as int,
        firstFrameOffset: j['firstFrame'] as int?,
        events: [for (final e in (j['events']! as List).cast<Map<String, Object?>>()) CardEvent.fromJson(e)],
        hasVad: j['vad']! as bool,
      );
}

/// Where a file's card lives: beside its chunks, under a name nothing else reads.
File cardFileFor(RawChunkStore store, RawFileKey key) => File('${store.folderOf(key).path}/${key.stem}.card');

Future<FileCard?> loadCard(RawChunkStore store, RawFileKey key) async {
  final file = cardFileFor(store, key);
  if (!await file.exists()) return null;
  try {
    final card = FileCard.decode(await file.readAsBytes());
    // Another file's card under this name describes other bytes.
    return card.key == key ? card : null;
  } catch (_) {
    return null; // torn or from another layout: a card can always be rebuilt
  }
}

Future<void> saveCard(RawChunkStore store, FileCard card) async {
  final file = cardFileFor(store, card.key);
  await file.parent.create(recursive: true);
  await AtomicFile.writeBytes(file, card.encode());
}
