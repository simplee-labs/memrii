import 'dart:typed_data';

import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';

/// Automatic mode as the app ships it: Silero, 120 s split, 3 s of speech.
const autoPolicy = PlanPolicy(
  vadEnabled: true,
  speechThreshold: 0.5,
  silenceSplitMs: 120000,
  minSpeechMs: 3000,
  maxChunkMs: 0x7FFFFFFFFFFFFFFF,
  manual: false,
);

/// Manual mode: no VAD, no silence split; Record Start/Stop are the boundaries.
const manualPolicy = PlanPolicy(
  vadEnabled: false,
  speechThreshold: 0.5,
  silenceSplitMs: 0,
  minSpeechMs: 0,
  maxChunkMs: 0x7FFFFFFFFFFFFFFF,
  manual: true,
);

const speech = 0.9;

/// Names a file in its frames' payloads: its `timerStart` (low 20 bits) and session (11
/// bits). Files of one session start less than 12 days apart.
int frameTag(RawFileKey k) => (k.timerStart & 0xFFFFF) | (((k.sessionId ?? 0) & 0x7FF) << 20);
const quiet = 0.1;

/// Builds a bin the way the firmware writes it, keeping the Omi's clock and uptime as it
/// goes, with each frame's speech probability for the card.
class Bin {
  final RawFileKey key;
  final _bytes = BytesBuilder();
  final _speech = <double>[];
  final _decoded = <int>[];

  /// The time the next frame starts.
  int clockMs;

  /// The uptime after the last frame, as the planner counts it.
  int uptimeMs;

  Bin(int startMs, {int session = 7, this.uptimeMs = 100000, bool header = true, int? keySeconds, int? headerUtcMs})
      : key = RawFileKey(keySeconds ?? startMs ~/ 1000, session),
        clockMs = startMs {
    if (header) {
      _bytes.add((ByteData(36)
            ..setUint32(0, 0xFFFFFFFB, Endian.little)
            ..setUint32(4, 28, Endian.little)
            ..setUint64(8, headerUtcMs ?? startMs, Endian.little)
            ..setUint64(16, uptimeMs, Endian.little)
            ..setUint32(28, session, Endian.little)
            ..setUint32(32, 1, Endian.little))
          .buffer
          .asUint8List());
    }
  }

  /// The next file of the same boot, [gapMs] after this one's last frame ends.
  Bin next({int gapMs = 0, int? session, int? uptimeMs}) =>
      Bin(clockMs + gapMs, session: session ?? key.sessionId!, uptimeMs: uptimeMs ?? this.uptimeMs + gapMs);

  int get frameCount => _speech.length;
  int get length => _bytes.length;

  /// Each frame's record offset, as written (not parsed back).
  final frameOffsetsWritten = <int>[];

  /// Each frame, whether it can be decoded.
  List<int> get decodable => List.unmodifiable(_decoded);

  /// [n] frames with speech probability [p] (−1: no VAD window completed in it). Each
  /// 8-byte payload names the frame: its index in the file (bit 31 set when it cannot be
  /// decoded) and the file's [frameTag], which the publication tests' fake decoder
  /// renders into its samples. The planner never reads payloads.
  Bin frames(int n, {double p = -1, bool decoded = true}) {
    for (var i = 0; i < n; i++) {
      frameOffsetsWritten.add(_bytes.length);
      _bytes.add((ByteData(12)
            ..setUint32(0, 8, Endian.little)
            ..setUint32(4, _speech.length | (decoded ? 0 : 0x80000000), Endian.little)
            ..setUint32(8, frameTag(key), Endian.little))
          .buffer
          .asUint8List());
      _speech.add(p);
      _decoded.add(decoded ? 1 : 0);
    }
    clockMs += n * frameMs;
    uptimeMs += n * frameMs;
    return this;
  }

  Bin _marker(int tag, int utcMs, int uptimeMs) {
    _bytes.add((ByteData(20)
          ..setUint32(0, tag, Endian.little)
          ..setUint64(4, utcMs, Endian.little)
          ..setUint32(12, uptimeMs, Endian.little)
          ..setUint32(16, key.sessionId!, Endian.little))
        .buffer
        .asUint8List());
    return this;
  }

  /// The id the next record will have.
  EventId get nextId => EventId(key, _bytes.length);

  Bin tap({int? atMs}) => _marker(0xFFFFFFFE, atMs ?? clockMs, uptimeMs);
  Bin stop({int? atMs}) => _marker(0xFFFFFFFC, atMs ?? clockMs, uptimeMs);
  Bin priority({int? atMs, int? uptimeMs}) => _marker(0xFFFFFFF8, atMs ?? clockMs, uptimeMs ?? this.uptimeMs);
  Bin muteOn({int? atMs}) => _marker(0xFFFFFFFA, atMs ?? clockMs, uptimeMs);
  Bin muteOff({int? atMs}) => _marker(0xFFFFFFF9, atMs ?? clockMs, uptimeMs);

  /// The Omi slept [gapMs] and woke: a resume marker (whole seconds), after which the clock
  /// continues from it. [clockSet] makes it a clock correction: the time jumps by [gapMs]
  /// (either way) while uptime moves only [elapsedMs].
  Bin resume(int gapMs, {bool clockSet = false, int elapsedMs = 0, bool clockless = false}) {
    final atMs = ((clockMs + gapMs) ~/ 1000) * 1000;
    final upMs = clockSet ? uptimeMs + elapsedMs : uptimeMs + (atMs - clockMs);
    _bytes.add((ByteData(20)
          ..setUint32(0, 0xFFFFFFFD, Endian.little)
          ..setUint32(4, clockless ? 0 : atMs ~/ 1000, Endian.little)
          ..setUint32(8, upMs, Endian.little))
        .buffer
        .asUint8List());
    clockMs = atMs;
    uptimeMs = upMs;
    return this;
  }

  Uint8List get bytes => _bytes.toBytes();

  PlanFile file({
    SourceLifecycle lifecycle = SourceLifecycle.complete,
    bool hasVad = true,
    bool setAside = false,
    bool withAudio = true,
    int? firstSealedAtMs,
  }) =>
      PlanFile(
        key: key,
        records: parseRecords(bytes),
        audio:
            withAudio ? FrameAudio(decoded: Uint8List.fromList(_decoded), speech: Float32List.fromList(_speech)) : null,
        hasVad: hasVad,
        lifecycle: lifecycle,
        setAside: setAside,
        firstSealedAtMs: firstSealedAtMs,
      );

  /// What is left of this file once the gate released it: its receipt.
  PlanFile receipt({bool hasVad = true, int? firstSealedAtMs}) {
    final f = file();
    return PlanFile.released(
        EventSummary(
          key: key,
          length: length,
          frameCount: f.frameCount,
          firstFrameOffset: f.firstFrameOffset,
          events: f.events,
          hasVad: hasVad,
        ),
        firstSealedAtMs: firstSealedAtMs);
  }

  /// Force at the end of what this file holds.
  PlanBoundary get force => PlanBoundary(BoundaryKind.force, key, length);
}

/// Which sessions have ended, as the Omi's own session ids would show it: every session
/// but the newest, each ending when the next began. Tests date a session by its first
/// file; the planner itself is never told an order, only this.
Map<int?, int?> endedSessionsOf(Iterable<({RawFileKey key, int startMs})> files) {
  final first = <int?, ({RawFileKey key, int startMs})>{};
  for (final f in files) {
    final had = first[f.key.sessionId];
    if (had == null || compareKeys(f.key, had.key) < 0) first[f.key.sessionId] = f;
  }
  final order = first.values.toList()..sort((a, b) => a.startMs.compareTo(b.startMs));
  return {for (var i = 0; i + 1 < order.length; i++) order[i].key.sessionId: order[i + 1].startMs};
}

/// Each file with the time it starts, for [endedSessionsOf].
List<({RawFileKey key, int startMs})> startsOf(Iterable<PlanFile> files, [Iterable<RawFileKey> missing = const []]) => [
      for (final f in files) (key: f.key, startMs: f.header?.utcMs ?? f.key.timerStart * 1000),
      for (final k in missing) (key: k, startMs: k.timerStart * 1000),
    ];

Plan planOf(
  List<PlanFile> files, {
  PlanPolicy policy = autoPolicy,
  PolicyHistory? policies,
  List<RawFileKey> missing = const [],
  Set<RawFileKey> waived = const {},
  List<PlanBoundary> boundaries = const [],
  PlanOwnership owned = const PlanOwnership(),
  int capMinutes = 120,
  CapHistory? caps,
  Map<int?, int?>? endedSessions,
  QuietMark? quiet,
}) =>
    plan(PlanInput(
      files: files,
      policies: policies ?? PolicyHistory(policy),
      caps: caps ?? CapHistory.constant(capMinutes),
      missing: missing,
      waived: waived,
      boundaries: boundaries,
      owned: owned,
      endedSessions: endedSessions ?? endedSessionsOf(startsOf(files, missing)),
      quiet: quiet,
    ));

/// The quiet mark [afterMs] past where [b] has got to, by its clock and its uptime alike
/// ([clockMs] and [uptimeMs] move it on either alone), for [b]'s session.
QuietMark quietAfter(Bin b, int afterMs, {int? clockMs, int? uptimeMs}) => QuietMark(
      b.clockMs + (clockMs ?? afterMs),
      {b.key.sessionId!: (b.uptimeMs + (uptimeMs ?? afterMs)) & 0xFFFFFFFF},
    );

/// What is left of [f] once the gate released it: its receipt, from its card.
PlanFile receiptOf(PlanFile f) => PlanFile.released(
    EventSummary(
      key: f.key,
      length: f.parsedEnd,
      frameCount: f.frameCount,
      firstFrameOffset: f.firstFrameOffset,
      events: f.events,
      hasVad: f.hasVad,
    ),
    firstSealedAtMs: f.firstSealedAtMs);

/// Whether the gate could release [f]: terminal, its card here, every frame and every tap
/// and priority start owned.
bool releasable(PlanFile f, PlanOwnership owned) {
  if (!f.lifecycle.isTerminal || f.audio == null || f.setAside || f.released) return false;
  final covered = (owned.frames[f.key] ?? const []).fold<int>(0, (n, r) => n + r.$2 - r.$1);
  if (covered != f.frameCount) return false;
  return f.events
      .where((e) => e.kind == CardEventKind.tap || e.kind == CardEventKind.priorityStart)
      .every((e) => owned.events.contains(EventId(f.key, e.offset)));
}

/// What publishing [items] makes owned.
PlanOwnership ownershipOf(Iterable<PlanItem> items, [PlanOwnership base = const PlanOwnership()]) {
  final frames = <RawFileKey, List<(int, int)>>{
    for (final e in base.frames.entries) e.key: [...e.value]
  };
  final events = {...base.events};
  for (final item in items) {
    for (final s in item.spans) {
      frames.putIfAbsent(s.key, () => []).add((s.first, s.end));
    }
    events.addAll(item.events);
  }
  for (final ranges in frames.values) {
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].$1 < ranges[i - 1].$2) throw StateError('overlapping ownership: $ranges');
    }
  }
  return PlanOwnership(frames: frames, events: events);
}

List<PlannedRecording> recordingsOf(Plan p) => p.items.whereType<PlannedRecording>().toList();
List<PlannedDiscard> discardsOf(Plan p) => p.items.whereType<PlannedDiscard>().toList();

/// Every orphan marker: those of conversations that closed with no audio, and those of
/// discarded audio.
List<PlannedMarker> orphansOf(Plan p) => [
      for (final i in p.items)
        if (i is PlannedOrphans) ...i.markers else if (i is PlannedDiscard) ...i.orphans
    ];
