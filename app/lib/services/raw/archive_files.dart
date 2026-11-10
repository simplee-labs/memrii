// What publication writes into the archive (RECORDINGS_PIPELINE_REDESIGN.md §4): reserved
// names, each recording's `.meta`, the marker EDLs and the discard records, in the formats
// today's readers already understand (Conversation.fromFile, getMarkerConversations,
// DiscardStore).
//
// Not switched on yet (see raw_chunks.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';

/// A recordings folder: the local date, as every date folder is named.
String localDateOf(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

final _digits = RegExp(r'^\d+$');

/// The milliseconds a file in a recordings folder is named by: the first all-digit `_`
/// part of its name before the first dot, or null. Markers and the discard list name no
/// recording.
int? archiveNameMs(String filename) {
  if (filename.startsWith('marker_') || filename.startsWith('discards.jsonl')) return null;
  final base = filename.split('.').first;
  for (final part in base.split('_')) {
    if (_digits.hasMatch(part)) return int.parse(part);
  }
  return null;
}

/// A recording's reserved name. A name is identity, not a capture time: it can sit a few
/// ms after the recording's true start, which alone sets the date folder.
class RecordingName {
  final String date;
  final String prefix;
  final int nameMs;

  const RecordingName(this.date, this.prefix, this.nameMs);

  String get stem => '${prefix}_$nameMs';
  String audio(String extension) => '$stem.$extension';
  String get meta => '$stem.meta';

  /// The Opus frame sidecar (RecordingSidecars.opusFramesPathIn): `recording_fs320_<ms>`
  /// whatever the prefix.
  String get sidecar => 'recording_fs320_$nameMs.bin';

  /// The ledger's owner id.
  String get id => '$date/$stem';
}

/// Picks names nothing in the archive uses yet, nor anything reserved before by the same
/// transaction.
class NameReserver {
  final String recordingsRoot;
  final _names = <String, Set<String>>{};

  NameReserver(this.recordingsRoot);

  Future<Set<String>> _folder(String date) async {
    final had = _names[date];
    if (had != null) return had;
    final dir = Directory('$recordingsRoot/$date');
    final names = <String>{};
    if (await dir.exists()) {
      await for (final e in dir.list(followLinks: false)) {
        names.add(e.uri.pathSegments.lastWhere((s) => s.isNotEmpty));
      }
    }
    return _names[date] = names;
  }

  /// The first ms at or after [startMs] that no file names, in the true start's folder or
  /// in the folder of the ms itself (one past midnight is another day's folder), across
  /// every stem: audio in both formats, meta, sidecars, drafts, crops, `unknown_` names.
  Future<RecordingName> recording(int startMs, {required bool derived}) async {
    final date = localDateOf(startMs);
    var ms = startMs;
    while (await _taken(date, ms) || await _taken(localDateOf(ms), ms)) {
      ms++;
    }
    final name = RecordingName(date, derived ? 'unknown' : 'recording', ms);
    (await _folder(date)).add(name.meta);
    if (localDateOf(ms) != date) (await _folder(localDateOf(ms))).add(name.meta);
    return name;
  }

  Future<bool> _taken(String date, int ms) async => (await _folder(date)).any((n) => archiveNameMs(n) == ms);

  /// `marker_<ms>.edl`, or `marker_<ms>_<n>.edl` when another marker has that ms already.
  Future<String> edl(String date, int markerMs) async {
    final names = await _folder(date);
    for (var n = 0;; n++) {
      final name = n == 0 ? 'marker_$markerMs.edl' : 'marker_${markerMs}_$n.edl';
      if (names.add(name)) return name;
    }
  }
}

/// The upload identity the meta carries: the device's first six MAC digits and the name
/// the recording is published under (`recording_` whatever the prefix, as today).
String? uploadKeyOf(String deviceId, int nameMs, String extension) {
  final id = deviceId.replaceAll(':', '').toUpperCase();
  if (id.length < 6) return null;
  return '${id.substring(0, 6)}_recording_$nameMs.$extension';
}

/// A recording's `.meta`, as VadAudioProcessor._saveMetadata writes it: samples, duration,
/// 200 peaks, session, start uptime (whole seconds), the upload key, four flag bytes, then
/// the source files as a length-prefixed JSON list. Never a fifth flag byte.
Uint8List buildMeta({
  required int totalSamples,
  required Uint16List peaks,
  required int? sessionId,
  required int? startUptimeSeconds,
  required String? uploadKey,
  required bool forceSynced,
  required bool capEnded,
  required bool silero,
  required bool? manual,
  required List<String> relativeBins,
}) {
  final fixed = ByteData(416);
  fixed.setUint32(0, totalSamples, Endian.little);
  fixed.setUint32(4, totalSamples * 1000 ~/ 16000, Endian.little);
  for (var i = 0; i < 200; i++) {
    fixed.setUint16(8 + i * 2, i < peaks.length ? peaks[i] : 0, Endian.little);
  }
  fixed.setUint32(408, sessionId ?? 0, Endian.little);
  // 0 reads as unknown (Conversation.startUptimeMs); a start in the Omi's first second
  // is written as 1 s, within the second the field already rounds away.
  fixed.setUint32(
      412, startUptimeSeconds == null ? 0 : (startUptimeSeconds < 1 ? 1 : startUptimeSeconds), Endian.little);
  final key = uploadKey == null ? const <int>[] : ascii.encode(uploadKey);
  final keyBytes = key.length > 255 ? key.sublist(0, 255) : key;
  final bins = utf8.encode(jsonEncode([...relativeBins]..sort()));
  final out = BytesBuilder(copy: false)
    ..add(fixed.buffer.asUint8List())
    ..addByte(keyBytes.length)
    ..add(keyBytes)
    ..addByte(0) // passthrough: set later by the integrations layer
    ..addByte(forceSynced ? 1 : 0)
    ..addByte(capEnded ? 1 : 0)
    // bit0 Silero; hard start and hard end (0x02, 0x04) are no longer written (§10); the
    // mode pair (0x08 known, 0x10 manual); clock-corrected (0x20) is the clock pass's;
    // m4a-pending (0x40) is never needed, the format is final when published.
    ..addByte((silero ? 0x01 : 0) | (manual == null ? 0 : 0x08 | (manual ? 0x10 : 0)))
    ..add((ByteData(4)..setUint32(0, bins.length, Endian.little)).buffer.asUint8List())
    ..add(bins);
  return out.takeBytes();
}

/// A marker's EDL, as today's writer makes one: in a recording, or (with an empty
/// segment) an orphan.
Map<String, Object?> edlPayload({
  required PlannedMarker marker,
  required String segmentFilename,
  required int durationMs,
}) =>
    {
      'markerTimestampMs': marker.markerMs,
      'segmentFilename': segmentFilename,
      'markerOffsetMs': segmentFilename.isEmpty ? 0 : marker.offsetMs,
      'cropStartMs': 0,
      'cropEndMs': segmentFilename.isEmpty ? 0 : durationMs,
      'userSaved': false,
      'isHighPriority': marker.highPriority,
    };

/// An EDL's marker time, or null when it cannot be read.
int? edlMarkerMs(String json) {
  try {
    final ms = (jsonDecode(json) as Map)['markerTimestampMs'];
    return ms is int ? ms : null;
  } catch (_) {
    return null;
  }
}

/// A discard's id: where its first frame is, or its mute-on, or where it closed. Frames
/// and markers have one owner each, so no two discards share one.
String discardIdOf(PlannedDiscard d, Map<RawFileKey, List<(int, int)>> bytes) {
  if (d.spans.isNotEmpty) {
    final key = d.spans.first.key;
    return '${key.rel}@${bytes[key]!.first.$1}';
  }
  if (d.muteOn != null) return '${d.muteOn!.key.rel}@m${d.muteOn!.offset}';
  return '${d.closedAt.key.rel}@c${d.closedAt.offset}';
}

/// A discard's line in `discards.jsonl`: today's fields, plus its id and its exact,
/// disjoint byte ranges per source file.
Map<String, Object?> discardRecordOf(PlannedDiscard d, String id, Map<RawFileKey, List<(int, int)>> bytes) {
  final rels = [for (final k in bytes.keys) k.rel]..sort();
  return {
    'id': id,
    'startMs': d.startMs,
    'endMs': d.endMs,
    'audioMs': d.audioMs,
    'reason': d.kind.reason,
    'maxVoiceProb': d.maxVoiceProb,
    'relativeBins': rels,
    'binRanges': {
      for (final e in bytes.entries)
        e.key.rel: [
          for (final (s, end) in e.value) [s, end]
        ]
    },
  };
}
