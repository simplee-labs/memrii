import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/utils/logger.dart';

/// All persistence and querying of VAD-dropped stretches recorded in
/// `recordings/<date>/discards.jsonl`. Extracted from RecordingsManager so the
/// discard ledger (write / read / coalesce / delete / expire) lives in one
/// cohesive, independently-testable unit. RecordingsManager keeps thin static
/// wrappers so existing call sites are unchanged.
class DiscardStore {
  DiscardStore._();

  /// Consecutive discard records whose inter-record gap is within this tolerance
  /// are coalesced into a single entry by [getDiscardsForDate], so a long
  /// ambient-noise period surfaces as one row instead of dozens of back-to-back
  /// ~2-minute ghosts. Back-to-back chunks abut at ~0 gap (the next conversation
  /// is re-anchored to the frame right after a silence split); this window only
  /// needs to absorb RTC drift / inter-file rounding. It is far below the
  /// multi-minute gap a real saved recording or a device-idle (AAD-sleep) period
  /// introduces, so genuinely separate noise periods stay separate.
  static const Duration discardMergeGap = Duration(seconds: 30);

  /// Parses a persisted `binRanges` map tolerantly into per-bin DISJOINT
  /// intervals (`{rel: [[s, e], ...]}`). A single record is written as a flat
  /// `[startByte, endByte]` (one contiguous span); accepts both that flat form
  /// and a nested list of pairs. Absent/malformed ⇒ empty map (Recover falls
  /// back to whole-bin).
  static Map<String, List<List<int>>> _parseBinRanges(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, List<List<int>>>{};
    raw.forEach((k, v) {
      if (k is! String || v is! List || v.isEmpty) return;
      // Flat `[s, e]` (the persisted single-record form) vs nested `[[s, e], ...]`.
      final pairs = v.first is List ? v : [v];
      final intervals = <List<int>>[];
      for (final p in pairs) {
        if (p is List && p.length == 2) {
          final s = p[0], e = p[1];
          if (s is int && e is int && e > s) intervals.add([s, e]);
        }
      }
      if (intervals.isNotEmpty) out[k] = _mergeIntervals(intervals);
    });
    return out;
  }

  /// Sorts and merges only OVERLAPPING or byte-ADJACENT intervals (`end == next
  /// start`). Disjoint intervals (a real gap between them) stay separate, so a
  /// gap that belongs to an un-discarded recording is never swallowed.
  static List<List<int>> _mergeIntervals(List<List<int>> intervals) {
    if (intervals.length < 2) return intervals;
    final sorted = [...intervals]..sort((a, b) => a[0].compareTo(b[0]));
    final out = <List<int>>[
      [sorted.first[0], sorted.first[1]]
    ];
    for (var i = 1; i < sorted.length; i++) {
      final last = out.last;
      final cur = sorted[i];
      if (cur[0] <= last[1]) {
        if (cur[1] > last[1]) last[1] = cur[1];
      } else {
        out.add([cur[0], cur[1]]);
      }
    }
    return out;
  }

  /// Unions two per-bin interval maps, keeping each bin's spans DISJOINT. Unlike
  /// a `[min, max]` hull, this preserves the gap between two non-adjacent noise
  /// stretches in the same bin — the gap is un-discarded audio that Recover must
  /// not re-derive.
  static Map<String, List<List<int>>> _unionBinRanges(Map<String, List<List<int>>> a, Map<String, List<List<int>>> b) {
    final out = <String, List<List<int>>>{
      for (final e in a.entries)
        e.key: [
          for (final iv in e.value) [iv[0], iv[1]]
        ]
    };
    b.forEach((k, v) {
      final cur = out[k];
      if (cur == null) {
        out[k] = [
          for (final iv in v) [iv[0], iv[1]]
        ];
      } else {
        out[k] = _mergeIntervals([...cur, ...v]);
      }
    });
    return out;
  }

  /// Parses `recordings/<dateString>/discards.jsonl` into [DiscardRecord]s.
  /// Returns an empty list if the file does not exist (or is deleted while it is
  /// read, as Delete Day does). Malformed lines are skipped with a warning.
  static Future<List<DiscardRecord>> getDiscardsForDate(String dateString) async {
    final directory = await getApplicationDocumentsDirectory();
    final jsonl = File('${directory.path}/recordings/$dateString/discards.jsonl');
    if (!await jsonl.exists()) return const [];
    final String text;
    try {
      text = await jsonl.readAsString();
    } on FileSystemException {
      return const [];
    }
    final out = <DiscardRecord>[];
    final seen = <String>{};
    for (final line in text.split('\n')) {
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        final rec = DiscardRecord(
          startTime: DateTime.fromMillisecondsSinceEpoch(m['startMs'] as int),
          endTime: DateTime.fromMillisecondsSinceEpoch(m['endMs'] as int),
          reason: m['reason'] as String,
          maxVoiceProb: (m['maxVoiceProb'] as num).toDouble(),
          relativeBins: (m['relativeBins'] as List).cast<String>(),
          binRanges: _parseBinRanges(m['binRanges']),
          audioMs: (m['audioMs'] as num?)?.toInt() ?? 0,
          sourceJsonl: jsonl,
          pipelineIds: [if (m['id'] is String) m['id'] as String],
        );
        if (rec.reason == 'silence_trimmed') continue;
        if (seen.add(rec.id)) out.add(rec);
      } catch (e) {
        Logger.error('DiscardStore: skipping malformed discard line in ${jsonl.path}: $e');
      }
    }
    out.sort((a, b) => a.startTime.compareTo(b.startTime));
    return _coalesceDiscards(out);
  }

  /// Merges time-adjacent [DiscardRecord]s (input MUST be sorted by startTime)
  /// so a continuous noise/silence period reads as one entry. The merged record
  /// spans `[first.start, max(end)]`, unions the referenced bins, keeps the
  /// highest `maxVoiceProb`, and reports a noise reason if any constituent was
  /// noise (so the UI's noise-vs-too-short label stays accurate for the common
  /// ambient-noise case). Two records merge when the later one starts within
  /// [discardMergeGap] of the running end — overlaps included.
  static List<DiscardRecord> _coalesceDiscards(List<DiscardRecord> sorted) {
    if (sorted.length < 2) return sorted;
    final merged = <DiscardRecord>[];

    DateTime start = sorted.first.startTime;
    DateTime end = sorted.first.endTime;
    double maxProb = sorted.first.maxVoiceProb;
    final bins = <String>{...sorted.first.relativeBins};
    Map<String, List<List<int>>> ranges = sorted.first.binRanges;
    // Recorded-audio length is ADDITIVE across constituents (the gaps between
    // them carry no audio), so sum it rather than spanning first.start→max.end.
    int audioMs = sorted.first.audioMs;
    String reason = sorted.first.reason;
    bool noise = sorted.first.isNoise;
    File src = sorted.first.sourceJsonl;
    final ids = <String>[...sorted.first.pipelineIds];

    DiscardRecord build() => DiscardRecord(
          startTime: start,
          endTime: end,
          reason: reason,
          maxVoiceProb: maxProb,
          relativeBins: bins.toList()..sort(),
          binRanges: ranges,
          audioMs: audioMs,
          sourceJsonl: src,
          pipelineIds: [...ids],
        );

    for (var i = 1; i < sorted.length; i++) {
      final r = sorted[i];
      // Muted intervals never merge — they're a distinct kind (no bins, delete-only),
      // so a muted record always flushes as its own ghost row and is never absorbed
      // into an adjacent noise/too-short discard (or vice versa).
      final mergeable = reason != 'muted' && !r.isMuted;
      if (mergeable && r.startTime.difference(end) <= discardMergeGap) {
        if (r.endTime.isAfter(end)) end = r.endTime;
        if (r.maxVoiceProb > maxProb) maxProb = r.maxVoiceProb;
        bins.addAll(r.relativeBins);
        ranges = _unionBinRanges(ranges, r.binRanges);
        audioMs += r.audioMs;
        ids.addAll(r.pipelineIds);
        if (!noise && r.isNoise) {
          noise = true;
          reason = r.reason;
        }
      } else {
        merged.add(build());
        start = r.startTime;
        end = r.endTime;
        maxProb = r.maxVoiceProb;
        bins
          ..clear()
          ..addAll(r.relativeBins);
        ranges = r.binRanges;
        audioMs = r.audioMs;
        ids
          ..clear()
          ..addAll(r.pipelineIds);
        reason = r.reason;
        noise = r.isNoise;
        src = r.sourceJsonl;
      }
    }
    merged.add(build());
    return merged;
  }
}
