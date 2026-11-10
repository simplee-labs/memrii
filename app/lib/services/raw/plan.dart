// The plan (RECORDINGS_PIPELINE_REDESIGN.md §3): what the recordings are, worked out from
// scratch from the cards every time. Pure: the same inputs give the same plan, and
// nothing about processing history is an input (I7).
//
// Two layers, walked together in time order, one session at a time:
//
// - The event layer follows the markers: the Omi's clock for every frame, stop and
//   resume, tap protection, Priority Recording, mute and the AAD flood guard. It reads
//   the stream alone, never how audio was split or saved (R1), so it is the same whether
//   or not anything has been published.
// - The conversation layer applies today's rules (VadAudioProcessor) to the frames:
//   speech, silence split, minimum speech, length cap, gaps, priority spans and marker
//   closes. It starts fresh at every close, from the event layer alone, so publishing a
//   closed item leaves the plan of everything after it unchanged (I8).
//
// Owned audio (a published item or a deletion) is a wall: a conversation closes before
// it and the next one starts after it. So is audio set aside or given up on, so that
// when it comes back it fits between the walls, in its place. A session is read only up
// to its first hole, audio known to exist that is not here (R2).
//
// Not switched on yet (see raw_chunks.dart).

import 'dart:math';
import 'dart:typed_data';

import 'package:omi/capture/capture_policy.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/raw_chunks.dart';

/// One Opus frame: 20 ms.
const int frameMs = 20;

/// Mirrors the firmware's VAD hold: a gap the Omi records is this much shorter than the
/// silence the user heard.
const int firmwareHoldMs = MemriiDefaultCapturePolicy.firmwareActivityHoldMs;

/// How long after a tap (or a Priority Recording start) every frame counts as speech and
/// no gap splits, as the firmware forces its gate open for that long.
const int tapProtectionMs = MemriiDefaultCapturePolicy.markerProtectionMs;

/// An inter-file gap this long or longer is padded with silence when a conversation
/// carries on across it.
const int fileGapPadMs = 10000;

/// When the clock and the uptime move apart by more than this (a resume's clock is in
/// whole seconds, and the RTC drifts), the clock was set: the uptime's move is the time
/// that passed.
const int clockSetToleranceMs = 5000;

/// A tap's own clock is used for it unless it is this far from the audio's.
const int tapDriftMs = 60000;

/// Added to the firmware's priority safety cap before the app cuts a span whose stop was
/// lost: the firmware's own stop arrives a moment after the cap.
const int priorityCapGraceMs = 2 * 60 * 1000;

/// The bound on a Priority Recording when the firmware cap is 0 (none).
const int priorityFallbackCapMs = 6 * 60 * 60 * 1000;

/// A resume gap this long inside a Priority Recording means the Omi already left
/// force-capture: force-capture never sleeps, so its own resumes are sub-second.
const int priorityStaleGapMs = 15 * 1000;

/// Without Silero, a run of [aadFloodRun] resumes each closing less than
/// [aadFloodFloorMs] of audio is a clock-anchor fault, not speech: later resumes stitch.
const int aadFloodFloorMs = 1000;
const int aadFloodRun = 3;

/// No recording is longer: past it, a conversation continues as a new part.
const int dayLimitMs = 24 * 60 * 60 * 1000;

const int _minValidEpochSeconds = 946684800;

/// The rules a recording mode sets for cutting audio.
class PlanPolicy {
  final bool vadEnabled;
  final double speechThreshold;

  /// 0: silence never splits (manual mode).
  final int silenceSplitMs;
  final int minSpeechMs;
  final int maxChunkMs;

  /// The mode label for the recording's meta: true manual, false automatic, null unknown.
  final bool? manual;

  const PlanPolicy({
    required this.vadEnabled,
    required this.speechThreshold,
    required this.silenceSplitMs,
    required this.minSpeechMs,
    required this.maxChunkMs,
    this.manual,
  });

  @override
  bool operator ==(Object other) =>
      other is PlanPolicy &&
      other.vadEnabled == vadEnabled &&
      other.speechThreshold == speechThreshold &&
      other.silenceSplitMs == silenceSplitMs &&
      other.minSpeechMs == minSpeechMs &&
      other.maxChunkMs == maxChunkMs &&
      other.manual == manual;

  @override
  int get hashCode => Object.hash(vadEnabled, speechThreshold, silenceSplitMs, minSpeechMs, maxChunkMs, manual);
}

/// Which policy each file was recorded under: the mode-switch history (each switch with
/// the policy that was live before it) and the current policy.
class PolicyHistory {
  /// Ascending by time: a file starting before `at` (and at or after the previous entry)
  /// was recorded under `before`.
  final List<({int atUtcSeconds, PlanPolicy before})> switches;
  final PlanPolicy current;

  const PolicyHistory(this.current, [this.switches = const []]);

  /// A file whose name carries no date (recorded before the clock was set) predates every
  /// switch, as today's mode-switch passes treat it.
  PlanPolicy forFile(RawFileKey key) {
    final start = key.timerStart > _minValidEpochSeconds ? key.timerStart : 0;
    for (final s in switches) {
      if (start < s.atUtcSeconds) return s.before;
    }
    return current;
  }
}

/// The firmware Priority Recording safety cap, as it was set over time.
class CapHistory {
  /// Ascending by time; the first entry also covers everything before it.
  final List<({int atMs, int minutes})> entries;

  CapHistory(this.entries) : assert(entries.isNotEmpty);

  CapHistory.constant(int minutes) : entries = [(atMs: 0, minutes: minutes)];

  /// How much audio a Priority Recording that started at [startMs] may take before the
  /// app cuts it: the cap in force then, plus grace, or the fallback bound when it was 0.
  int capMsAt(int startMs) {
    var minutes = entries.first.minutes;
    for (final e in entries) {
      if (e.atMs > startMs) break;
      minutes = e.minutes;
    }
    return _capMs(minutes);
  }

  /// The longest cap in force at any time up to [ms]: for a start the Omi could not date
  /// (before time sync, [ms] is when the phone sealed the file, after it), so a shorter cap
  /// set since never cuts it.
  int longestUpTo(int ms) {
    var best = _capMs(entries.first.minutes);
    for (final e in entries) {
      if (e.atMs > ms) break;
      best = max(best, _capMs(e.minutes));
    }
    return best;
  }

  static int _capMs(int minutes) => minutes <= 0 ? priorityFallbackCapMs : minutes * 60 * 1000 + priorityCapGraceMs;
}

/// A marker's identity: its file and byte offset.
class EventId implements Comparable<EventId> {
  final RawFileKey key;
  final int offset;

  const EventId(this.key, this.offset);

  @override
  bool operator ==(Object other) => other is EventId && other.key == key && other.offset == offset;

  @override
  int get hashCode => Object.hash(key, offset);

  @override
  int compareTo(EventId other) {
    final byKey = compareKeys(key, other.key);
    return byKey != 0 ? byKey : offset.compareTo(other.offset);
  }

  @override
  String toString() => '${key.stem}@$offset';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Files in the order the Omi wrote them within a session: by `timerStart`, numerically.
/// Before the clock was set it counts uptime seconds, which sorts before every date.
int compareKeys(RawFileKey a, RawFileKey b) {
  final byStart = a.timerStart.compareTo(b.timerStart);
  if (byStart != 0) return byStart;
  return (a.sessionId ?? -1).compareTo(b.sessionId ?? -1);
}

/// Consecutive frames `[first, end)` of one file.
class FrameSpan {
  final RawFileKey key;
  final int first;
  final int end;

  const FrameSpan(this.key, this.first, this.end);

  int get length => end - first;

  @override
  bool operator ==(Object other) => other is FrameSpan && other.key == key && other.first == first && other.end == end;

  @override
  int get hashCode => Object.hash(key, first, end);

  @override
  String toString() => '${key.stem}[$first,$end)';
}

/// One file as the planner sees it.
class PlanFile {
  final RawFileKey key;

  /// Every marker, the header included, in order.
  final List<CardEvent> events;
  final int frameCount;

  /// Each frame's record offset. Null for a released file, which its receipt describes.
  final Uint32List? frameOffsets;

  /// A released file's first frame offset, where its audio wall stands.
  final int? firstFrameOffset;

  /// The end of the last whole record.
  final int parsedEnd;

  /// Per-frame decode and speech, or null while the file has no usable card audio.
  final FrameAudio? audio;

  /// Whether the card's speech came from the VAD model; without it the AAD rules apply.
  final bool hasVad;

  /// Set aside after repeated failures: its markers still count, its frames wait.
  final bool setAside;

  /// Released by the gate (§6): chunks and card deleted, every frame owned, and every tap
  /// and Priority Recording start. Only its receipt's summary is left. It is walked
  /// exactly as its card would be with all its frames owned: its markers count, and its
  /// first frame is the audio wall. Its mute-ons are owned as the ledger says: one whose
  /// muted interval had not closed yet when the file was released is listed when it does.
  final bool released;

  final SourceLifecycle lifecycle;

  /// The fallback time anchor for a file the Omi could not date (recorded once, §1).
  final int? firstSealedAtMs;

  PlanFile({
    required this.key,
    required ParsedRecords records,
    required this.audio,
    required this.hasVad,
    required this.lifecycle,
    this.setAside = false,
    this.firstSealedAtMs,
  })  : events = records.events,
        frameCount = records.frameCount,
        frameOffsets = records.frameOffsets,
        firstFrameOffset = records.frameCount == 0 ? null : records.frameOffsets[0],
        parsedEnd = records.parsedEnd,
        released = false;

  /// A released file, from its receipt.
  PlanFile.released(EventSummary summary, {this.firstSealedAtMs})
      : key = summary.key,
        events = summary.events,
        frameCount = summary.frameCount,
        frameOffsets = null,
        firstFrameOffset = summary.firstFrameOffset,
        parsedEnd = summary.length,
        audio = null,
        hasVad = summary.hasVad,
        setAside = false,
        released = true,
        lifecycle = SourceLifecycle.complete;

  /// The metadata header at the file's start, the one that dates it.
  CardEvent? get header =>
      events.isNotEmpty && events.first.kind == CardEventKind.header && events.first.offset == 0 ? events.first : null;

  factory PlanFile.fromCard(FileCard card, LogicalRawFile file, {bool setAside = false}) => PlanFile(
        key: file.key,
        records: card.records,
        audio: card.audio,
        hasVad: card.hasVad,
        lifecycle: file.lifecycle,
        setAside: setAside,
        firstSealedAtMs: file.firstSealedAtMs,
      );
}

/// Audio already owned: frames and markers of published items, discards, orphan-marker
/// records and deletions, as the ledger holds them (§4).
class PlanOwnership {
  /// Owned frames per file, as sorted, disjoint `[first, end)` ranges.
  final Map<RawFileKey, List<(int, int)>> frames;

  /// Owned markers: taps and priority starts (in an EDL or an orphan record), and mute-ons
  /// whose muted interval was published.
  final Set<EventId> events;

  const PlanOwnership({this.frames = const {}, this.events = const {}});
}

enum BoundaryKind { force, rebuildEnd }

/// Force, or the end of a rebuild: everything here up to [offset] in [key] is to be
/// finished. Holes before it are waived, and what is open there closes (§7).
class PlanBoundary {
  final BoundaryKind kind;
  final RawFileKey key;

  /// The logical length of [key] when the boundary was made: records starting before it
  /// are inside.
  final int offset;

  const PlanBoundary(this.kind, this.key, this.offset);
}

class PlanInput {
  /// The files here.
  final List<PlanFile> files;

  /// Files the Omi lists that are not here.
  final List<RawFileKey> missing;

  /// Files whose hole is waived (held-back timeout): planning reads past them. They keep
  /// downloading; what arrives later is late audio.
  final Set<RawFileKey> waived;

  final List<PlanBoundary> boundaries;
  final PlanOwnership owned;
  final PolicyHistory policies;
  final CapHistory caps;

  /// Sessions the Omi has left (it restarted since), each with when the next one began
  /// if known: the bound for a mute still open in it. Durable evidence from the Omi's own
  /// session id as the app read it, never inferred from the files' dates, which a clock
  /// correction can reorder.
  final Map<int?, int?> endedSessions;

  const PlanInput({
    required this.files,
    required this.policies,
    required this.caps,
    this.missing = const [],
    this.waived = const {},
    this.boundaries = const [],
    this.owned = const PlanOwnership(),
    this.endedSessions = const {},
  });
}

/// Why an item ended.
enum CloseType {
  /// Continuous silence reached the policy's split.
  silence,

  /// A resume after a gap over the split.
  resumeGap,

  /// A gap between files over the split.
  fileGap,

  /// The policy's length cap.
  cap,

  /// The 24-hour limit: the conversation continues as a new part.
  dayLimit,

  stop,
  priorityStart,
  muteOn,

  /// A Priority Recording reached its safety cap: its stop was lost.
  priorityCap,

  /// A Priority Recording whose stop was lost, shown by a long resume gap.
  priorityStale,

  /// The next file was recorded under another policy.
  policy,

  /// The session ended: the Omi restarted.
  sessionEnd,

  force,
  rebuildEnd,

  /// Owned, set-aside or given-up audio follows.
  wall,

  /// A latched run (after a stop or mute-on) ended with its latch.
  latchEnd,

  /// A muted interval ended (mute off, or the session ended).
  unmute,

  /// Not the planner's: discarded audio the user recovered as one recording (§7).
  recovered,
}

/// Where an item closed: while handling the record at [offset] of [key], or, with offset
/// -1, at the start of [key].
class PlanPosition implements Comparable<PlanPosition> {
  final RawFileKey key;
  final int offset;

  const PlanPosition(this.key, this.offset);

  @override
  int compareTo(PlanPosition other) {
    final byKey = compareKeys(key, other.key);
    return byKey != 0 ? byKey : offset.compareTo(other.offset);
  }

  @override
  bool operator ==(Object other) => other is PlanPosition && other.key == key && other.offset == offset;

  @override
  int get hashCode => Object.hash(key, offset);

  @override
  String toString() => '${key.stem}@$offset';
}

/// A tap or Priority Recording start in a recording's EDL, or alone as an orphan.
class PlannedMarker {
  final EventId id;
  final int markerMs;

  /// Milliseconds of the recording before it.
  final int offsetMs;
  final bool highPriority;

  const PlannedMarker(this.id, this.markerMs, this.offsetMs, this.highPriority);

  @override
  bool operator ==(Object other) =>
      other is PlannedMarker &&
      other.id == id &&
      other.markerMs == markerMs &&
      other.offsetMs == offsetMs &&
      other.highPriority == highPriority;

  @override
  int get hashCode => Object.hash(id, markerMs, offsetMs, highPriority);

  @override
  String toString() => 'marker(${highPriority ? 'priority ' : ''}$id at +${offsetMs}ms)';
}

/// A piece of a recording's timeline: frames, or silence where the Omi slept.
sealed class PlanPiece {
  const PlanPiece();
  int get durationMs;
}

class FramesPiece extends PlanPiece {
  final FrameSpan span;
  const FramesPiece(this.span);
  @override
  int get durationMs => span.length * frameMs;
  @override
  bool operator ==(Object other) => other is FramesPiece && other.span == span;
  @override
  int get hashCode => span.hashCode;
  @override
  String toString() => '$span';
}

class SilencePiece extends PlanPiece {
  final int ms;
  const SilencePiece(this.ms);
  @override
  int get durationMs => ms;
  @override
  bool operator ==(Object other) => other is SilencePiece && other.ms == ms;
  @override
  int get hashCode => ms.hashCode;
  @override
  String toString() => 'silence(${ms}ms)';
}

/// Something the plan closed, ready to publish.
sealed class PlanItem {
  final int? sessionId;
  final CloseType closeType;
  final PlanPosition closedAt;
  const PlanItem(this.sessionId, this.closeType, this.closedAt);

  /// The frames it owns.
  List<FrameSpan> get spans;

  /// The markers it owns.
  List<EventId> get events;
}

class PlannedRecording extends PlanItem {
  final List<PlanPiece> pieces;
  final int startMs;

  /// Device uptime at the start, in whole seconds, when known.
  final int? startUptimeSeconds;

  /// The start comes from when the phone received the file, not from the Omi's clock.
  final bool derivedTime;

  final List<PlannedMarker> markers;
  final int durationMs;
  final int frameCount;

  /// Cut with Silero (rather than the AAD rules).
  final bool silero;

  final bool? manual;

  const PlannedRecording({
    required int? sessionId,
    required CloseType closeType,
    required PlanPosition closedAt,
    required this.pieces,
    required this.startMs,
    required this.startUptimeSeconds,
    required this.derivedTime,
    required this.markers,
    required this.durationMs,
    required this.frameCount,
    required this.silero,
    required this.manual,
  }) : super(sessionId, closeType, closedAt);

  @override
  List<FrameSpan> get spans => [
        for (final p in pieces)
          if (p is FramesPiece) p.span
      ];

  @override
  List<EventId> get events => [for (final m in markers) m.id];

  @override
  String toString() => 'recording(${closeType.name} at $closedAt: $startMs +${durationMs}ms, $pieces, $markers)';

  @override
  bool operator ==(Object other) =>
      other is PlannedRecording &&
      other.sessionId == sessionId &&
      other.closeType == closeType &&
      other.closedAt == closedAt &&
      _listEquals(other.pieces, pieces) &&
      other.startMs == startMs &&
      other.startUptimeSeconds == startUptimeSeconds &&
      other.derivedTime == derivedTime &&
      _listEquals(other.markers, markers) &&
      other.durationMs == durationMs &&
      other.frameCount == frameCount &&
      other.silero == silero &&
      other.manual == manual;

  @override
  int get hashCode => Object.hash(sessionId, closeType, closedAt, Object.hashAll(pieces), startMs, durationMs);
}

enum DiscardKind {
  noisePreSplit('noise_pre_split'),
  noiseSilenceSplit('noise_silence_split'),
  silenceOnly('silence_only'),
  flushNoise('flush_noise'),
  noiseMaxDuration('noise_max_duration'),

  /// Frames the Omi wrote just after a stop, before recording ended.
  afterStop('after_stop'),

  /// A muted interval, with any frames written in it.
  muted('muted');

  /// The reason `discards.jsonl` records.
  final String reason;
  const DiscardKind(this.reason);
}

class PlannedDiscard extends PlanItem {
  final DiscardKind kind;
  @override
  final List<FrameSpan> spans;
  final int startMs;
  final int endMs;

  /// Frames × 20 ms, without padding.
  final int audioMs;
  final double maxVoiceProb;

  /// The mute-on that opened a muted interval.
  final EventId? muteOn;

  /// Taps (and priority starts) the discarded audio held: each is kept as an orphan
  /// marker. Part of the same item, because they close together.
  final List<PlannedMarker> orphans;

  const PlannedDiscard({
    required int? sessionId,
    required CloseType closeType,
    required PlanPosition closedAt,
    required this.kind,
    required this.spans,
    required this.startMs,
    required this.endMs,
    required this.audioMs,
    required this.maxVoiceProb,
    this.muteOn,
    this.orphans = const [],
  }) : super(sessionId, closeType, closedAt);

  @override
  List<EventId> get events => [if (muteOn != null) muteOn!, for (final m in orphans) m.id];

  @override
  String toString() => 'discard(${kind.reason}, ${closeType.name} at $closedAt: $startMs-$endMs, $spans, $orphans)';

  @override
  bool operator ==(Object other) =>
      other is PlannedDiscard &&
      other.sessionId == sessionId &&
      other.closeType == closeType &&
      other.closedAt == closedAt &&
      other.kind == kind &&
      _listEquals(other.spans, spans) &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.audioMs == audioMs &&
      other.maxVoiceProb == maxVoiceProb &&
      other.muteOn == muteOn &&
      _listEquals(other.orphans, orphans);

  @override
  int get hashCode => Object.hash(sessionId, closeType, closedAt, kind, Object.hashAll(spans), startMs, endMs);
}

/// The markers of a conversation that closed with no audio: kept as orphan markers.
class PlannedOrphans extends PlanItem {
  final List<PlannedMarker> markers;

  const PlannedOrphans({
    required int? sessionId,
    required CloseType closeType,
    required PlanPosition closedAt,
    required this.markers,
  }) : super(sessionId, closeType, closedAt);

  @override
  List<FrameSpan> get spans => const [];

  @override
  List<EventId> get events => [for (final m in markers) m.id];

  @override
  String toString() => 'orphans(${closeType.name} at $closedAt: $markers)';

  @override
  bool operator ==(Object other) =>
      other is PlannedOrphans &&
      other.sessionId == sessionId &&
      other.closeType == closeType &&
      other.closedAt == closedAt &&
      _listEquals(other.markers, markers);

  @override
  int get hashCode => Object.hash(sessionId, closeType, closedAt, Object.hashAll(markers));
}

/// The conversation still open at the end of what was read: "in progress".
class OpenConversation {
  final int? sessionId;
  final int? startMs;
  final int durationMs;
  final int frameCount;
  final int markerCount;
  final bool inPriority;

  const OpenConversation({
    required this.sessionId,
    required this.startMs,
    required this.durationMs,
    required this.frameCount,
    required this.markerCount,
    required this.inPriority,
  });
}

class Plan {
  /// Closed items, in the order they closed within each session; sessions in time order.
  final List<PlanItem> items;

  /// Per session, the conversation open where reading stopped.
  final List<OpenConversation> open;

  /// Per session that stopped at a hole, where.
  final Map<int?, PlanPosition> stoppedAt;

  const Plan(this.items, this.open, this.stoppedAt);
}

/// Works out the plan.
Plan plan(PlanInput input) {
  final bySession = <int?, List<PlanFile>>{};
  for (final f in input.files) {
    bySession.putIfAbsent(f.key.sessionId, () => []).add(f);
  }
  final missingBySession = <int?, List<RawFileKey>>{};
  for (final k in input.missing) {
    missingBySession.putIfAbsent(k.sessionId, () => []).add(k);
  }
  final boundariesBySession = <int?, List<PlanBoundary>>{};
  for (final b in input.boundaries) {
    boundariesBySession.putIfAbsent(b.key.sessionId, () => []).add(b);
  }
  // Sessions are independent; this order is only the order of the output.
  final first = <int?, RawFileKey>{};
  for (final k in [for (final f in input.files) f.key, ...input.missing]) {
    final had = first[k.sessionId];
    if (had == null || compareKeys(k, had) < 0) first[k.sessionId] = k;
  }
  final sessions = first.keys.toList()..sort((a, b) => compareKeys(first[a]!, first[b]!));

  final items = <PlanItem>[];
  final open = <OpenConversation>[];
  final stopped = <int?, PlanPosition>{};
  for (final s in sessions) {
    final walker = _SessionWalker(
      input,
      s,
      (bySession[s] ?? [])..sort((a, b) => compareKeys(a.key, b.key)),
      (missingBySession[s] ?? [])..sort(compareKeys),
      boundariesBySession[s] ?? const [],
    );
    walker.walk();
    items.addAll(walker.items);
    final o = walker.openSummary();
    if (o != null) open.add(o);
    if (walker.stoppedAt != null) stopped[s] = walker.stoppedAt!;
  }
  return Plan(items, open, stopped);
}

/// When a file starts, by the best clock it has: its header, its name, or (before the
/// Omi's clock was set) when the phone first sealed it.
class _FileClock {
  final int startMs;

  /// Device uptime at the start, in full (a header's 64 bits), or null when the file does
  /// not say.
  final int? startUptimeMs;

  /// Dated by the phone (when it first sealed the file), not by the Omi's clock.
  final bool derived;

  const _FileClock(this.startMs, this.startUptimeMs, this.derived);

  factory _FileClock.of(PlanFile f) {
    final header = f.header;
    // The uptime is the header's, whatever its clock says. A pre-sync name is not read as
    // one: it holds the low 32 bits in whole seconds at best, bumped to keep names in order
    // (so after a wrap it runs on from before it).
    final uptime = header != null && header.uptimeMs > 0 ? header.uptimeMs : null;
    if (header != null && header.hasClock) return _FileClock(header.utcMs, uptime, false);
    if (f.key.timerStart > _minValidEpochSeconds) return _FileClock(f.key.timerStart * 1000, uptime, false);
    return _FileClock(f.firstSealedAtMs ?? 0, uptime, true);
  }
}

/// A conversation being planned.
class _Conversation {
  final PlanPolicy policy;
  final bool aad;
  final bool derived;
  bool forced;

  int? startMs;
  int? startUptimeMs;
  final pieces = <PlanPiece>[];
  RawFileKey? _spanKey;
  int _spanFirst = 0;
  int _spanEnd = 0;
  int frames = 0;
  int speechFrames = 0;
  int silenceRunMs = 0;
  int durationMs = 0;
  double maxProb = 0;
  final markers = <PlannedMarker>[];

  /// A tap's own clock in a conversation dated by the phone: (tap time, offset).
  (int, int)? calibration;

  _Conversation(this.policy, this.aad, this.derived, this.forced);

  bool get hasFrames => frames > 0;

  void addFrame(RawFileKey key, int index, int timeMs, int? uptimeMs) {
    if (frames == 0) {
      startMs = timeMs;
      startUptimeMs = uptimeMs;
    }
    if (_spanKey == key && _spanEnd == index) {
      _spanEnd++;
    } else {
      _flushSpan();
      _spanKey = key;
      _spanFirst = index;
      _spanEnd = index + 1;
    }
    frames++;
    durationMs += frameMs;
  }

  void addSilence(int ms) {
    _flushSpan();
    pieces.add(SilencePiece(ms));
    durationMs += ms;
  }

  void _flushSpan() {
    if (_spanKey == null) return;
    pieces.add(FramesPiece(FrameSpan(_spanKey!, _spanFirst, _spanEnd)));
    _spanKey = null;
  }

  List<PlanPiece> finishPieces() {
    _flushSpan();
    return pieces;
  }

  List<FrameSpan> spans() => [
        for (final p in finishPieces())
          if (p is FramesPiece) p.span
      ];
}

/// Frames written while latched after a stop or a mute-on.
class _Latched {
  final DiscardKind kind;
  final _spans = <FrameSpan>[];
  RawFileKey? _spanKey;
  int _spanFirst = 0;
  int _spanEnd = 0;
  int startMs = 0;
  int endMs = 0;
  int frames = 0;
  double maxProb = 0;

  _Latched(this.kind);

  void add(RawFileKey key, int index, int timeMs, double prob) {
    if (frames == 0) startMs = timeMs;
    endMs = timeMs + frameMs;
    frames++;
    if (prob > maxProb) maxProb = prob;
    if (_spanKey == key && _spanEnd == index) {
      _spanEnd++;
    } else {
      _flush();
      _spanKey = key;
      _spanFirst = index;
      _spanEnd = index + 1;
    }
  }

  void _flush() {
    if (_spanKey != null) _spans.add(FrameSpan(_spanKey!, _spanFirst, _spanEnd));
    _spanKey = null;
  }

  List<FrameSpan> spans() {
    _flush();
    return List.unmodifiable(_spans);
  }
}

class _SessionWalker {
  final PlanInput input;
  final int? sessionId;
  final List<PlanFile> files;
  final List<RawFileKey> missing;
  final List<PlanBoundary> _boundaries;

  final items = <PlanItem>[];
  PlanPosition? stoppedAt;

  // ---- event layer ----
  // The clock within the current file.
  int _anchorMs = 0;
  int _anchorFrame = 0;
  int _lastFrameMs = 0;

  /// The last moment both the time and the uptime are known: the start of the file, the
  /// end of the last frame, a priority start, a resume. [_pairMs] is its time, [_uptimeMs]
  /// its uptime, in full: the file's header's, run on by frames and markers (see
  /// [_uptimeDelta]); null when the file's header does not say it. A resume with no clock
  /// is dated from it by uptime, and silence is measured from it: [_silenceMs] is the
  /// silence since the last audio up to this moment.
  int _pairMs = 0;
  int? _uptimeMs;
  bool _derivedFile = false;

  /// The silence since the last audio frame (or priority start) up to [_pairMs], in real
  /// time: the uptime's move since then, or the clock's when the uptime is not known.
  int _silenceMs = 0;

  // Carried from file to file: where the stream was at the end of the file (padding is
  // measured from it), and the last moment both time and uptime were known there, with
  // the silence up to it (silence is measured from it).
  int? _prevPositionMs;
  int? _prevSilenceMs;
  int _prevPairMs = 0;
  int? _prevPairUptimeMs;
  PlanPolicy? _prevPolicy;
  bool? _prevAad;
  DiscardKind? _latch;
  int? _protectedUntil;
  bool _inPriority = false;
  int _priorityCapMs = 0;

  /// The device time elapsed since the priority start, as the firmware's own timer counts
  /// it: the uptime now less the uptime then. Frames add 20 ms each, and each gap the
  /// uptime's move, signed, so a marker a moment behind the frames' estimate corrects it
  /// (never a clock correction or a phone date; across a gap that may hide whole wraps, only
  /// what the uptime itself shows; where the uptime is not known, the clock's move).
  int _priorityElapsedMs = 0;
  bool _startAdjacent = false;
  int? _muteStartMs;
  EventId? _muteOn;
  int _floodCount = 0;
  bool _floodActive = false;
  int _framesSinceSplit = 0;

  // ---- conversation layer ----
  _Conversation? _conv;
  _Latched? _latched;

  // The file being walked.
  late PlanFile _file;
  late PlanPolicy _policy;
  late bool _aad;
  late List<(int, int)> _ownedFrames;
  int _ownedCursor = 0;
  int _boundary = 0;

  _SessionWalker(this.input, this.sessionId, this.files, this.missing, List<PlanBoundary> boundaries)
      : _boundaries = [...boundaries]..sort((a, b) {
            final byKey = compareKeys(a.key, b.key);
            return byKey != 0 ? byKey : a.offset.compareTo(b.offset);
          });

  bool get _sessionEnded => input.endedSessions.containsKey(sessionId);

  static const _always = 1 << 62;

  /// Up to where in [key] a hole is waived: everywhere when the held-back timeout gave
  /// it up or a boundary lies in a later file; up to the last boundary inside it; else
  /// nowhere (-1). Boundaries waive the holes before them, so the furthest one decides.
  int _waivedUntil(RawFileKey key) {
    if (input.waived.contains(key)) return _always;
    if (_boundaries.isEmpty) return -1;
    final last = _boundaries.last;
    final byKey = compareKeys(key, last.key);
    if (byKey < 0) return _always;
    return byKey == 0 ? last.offset : -1;
  }

  void walk() {
    var m = 0;
    for (final f in files) {
      // Files listed on the Omi that sort before this one.
      while (m < missing.length && compareKeys(missing[m], f.key) < 0) {
        if (!_passMissing(missing[m])) return;
        m++;
      }
      _passBoundariesBefore(f.key);
      if (!_walkFile(f)) return;
    }
    while (m < missing.length) {
      if (!_passMissing(missing[m])) return;
      m++;
    }
    _passBoundariesBefore(null);
    if (_sessionEnded) {
      final at = PlanPosition(files.isEmpty ? missing.last : files.last.key, 1 << 40);
      _closeConversation(CloseType.sessionEnd, DiscardKind.flushNoise, at);
      // Unknown, the end is bounded by where the stream was.
      _endMute(input.endedSessions[sessionId] ?? _prevPositionMs ?? 0, at, CloseType.sessionEnd);
      _closeLatched(CloseType.sessionEnd, at);
    }
  }

  /// A file the Omi lists that is not here: a hole, unless waived. Waived, it is a wall.
  bool _passMissing(RawFileKey key) {
    _passBoundariesBefore(key);
    if (_waivedUntil(key) != _always) {
      stoppedAt = PlanPosition(key, -1);
      return false;
    }
    final at = PlanPosition(key, -1);
    _closeConversation(CloseType.wall, DiscardKind.flushNoise, at);
    _closeLatched(CloseType.wall, at);
    return true;
  }

  /// Closes what is open at every boundary that sorts before [key] (all, when null).
  void _passBoundariesBefore(RawFileKey? key) {
    while (_boundary < _boundaries.length && (key == null || compareKeys(_boundaries[_boundary].key, key) < 0)) {
      _applyBoundary(_boundaries[_boundary], PlanPosition(_boundaries[_boundary].key, _boundaries[_boundary].offset));
      _boundary++;
    }
  }

  void _applyBoundary(PlanBoundary b, PlanPosition at) {
    final type = b.kind == BoundaryKind.force ? CloseType.force : CloseType.rebuildEnd;
    _closeConversation(type, DiscardKind.flushNoise, at);
    _closeLatched(type, at);
  }

  /// Walks one file. False when it stopped at a hole.
  bool _walkFile(PlanFile f) {
    _file = f;
    _policy = input.policies.forFile(f.key);
    _aad = !_policy.vadEnabled || !f.hasVad;
    _ownedFrames = f.released ? [(0, f.frameCount)] : input.owned.frames[f.key] ?? const [];
    _ownedCursor = 0;
    final clock = _FileClock.of(f);
    final startAt = PlanPosition(f.key, -1);

    // Frames not here to plan: a released or set-aside file is a wall whose markers still
    // count; one without its card is a hole, read only as far as it is waived.
    final framesHere = _framesHere(f);
    final readUntil = framesHere || f.setAside ? _always : _waivedUntil(f.key);
    if (readUntil < 0) {
      stoppedAt = startAt;
      return false;
    }

    // ---- between files ----
    // A different policy, or a card with VAD next to one without, changes the rules.
    final policyChanged = _prevPolicy != null && (_policy != _prevPolicy || _aad != _prevAad);
    var gapSplits = false;
    var clockJump = false;
    var gapMs = 0;
    var silenceMs = 0;
    if (_prevPositionMs != null) {
      gapMs = clock.startMs - _prevPositionMs!;
      final sinceMs = clock.startMs - _prevPairMs;
      // Both headers have the uptime in full.
      final moveMs =
          _prevPairUptimeMs == null || clock.startUptimeMs == null ? null : clock.startUptimeMs! - _prevPairUptimeMs!;
      final step = _measure(sinceMs, moveMs);
      clockJump = step.clockSet;
      silenceMs = _prevSilenceMs! + step.elapsedMs;
      _priorityElapsedMs += moveMs ?? step.elapsedMs;
      final within = _protectedUntil != null && clock.startMs <= _protectedUntil!;
      gapSplits = !within && !_inPriority && silenceMs > max(0, _policy.silenceSplitMs - firmwareHoldMs);
    }
    if (policyChanged || gapSplits) _floodReset();
    if (!framesHere) {
      _closeConversation(CloseType.wall, DiscardKind.flushNoise, startAt);
      _closeLatched(CloseType.wall, startAt);
    }
    if (policyChanged) _closeConversation(CloseType.policy, DiscardKind.flushNoise, startAt);
    final conv = _conv;
    if (_prevPositionMs != null && conv != null && conv.hasFrames) {
      if (gapSplits) {
        _closeConversation(CloseType.fileGap, DiscardKind.flushNoise, startAt);
      } else if (!_inPriority && conv.durationMs + gapMs >= conv.policy.maxChunkMs) {
        _closeConversation(CloseType.cap, DiscardKind.flushNoise, startAt);
      } else if (!clockJump && gapMs >= fileGapPadMs) {
        if (conv.durationMs + gapMs >= dayLimitMs) {
          _closeConversation(CloseType.dayLimit, DiscardKind.flushNoise, startAt, forceSave: true);
        } else {
          conv.addSilence(gapMs);
        }
      }
    }

    // ---- the file's clock ----
    _anchorMs = clock.startMs;
    _anchorFrame = 0;
    _lastFrameMs = clock.startMs;
    _derivedFile = clock.derived;
    // Uptime is the file's own (its header's) or unknown: one carried from another file
    // would date recordings by a stale value.
    _uptimeMs = clock.startUptimeMs;
    _pairMs = clock.startMs;
    _silenceMs = silenceMs;

    // ---- records ----
    final events = f.events;
    final offsets = f.frameOffsets;
    final speech = f.audio?.speech;
    var e = 0;
    final n = f.frameCount;
    for (var i = 0; i <= n; i++) {
      while (e < events.length && events[e].frameIndex == i) {
        final ev = events[e];
        if (ev.offset >= readUntil) return _stopAt(ev.offset);
        _beforeRecord(ev.offset);
        _event(ev);
        e++;
      }
      if (i == n) break;
      // A released file's frames are known only by count and where the first is: past its
      // wall at the first frame, nothing there can close with an item.
      final offset = offsets != null ? offsets[i] : (i == 0 ? f.firstFrameOffset ?? -1 : -1);
      if (offset >= readUntil) return _stopAt(offset);
      if (offset >= 0) _beforeRecord(offset);
      _frame(i, offset, framesHere, speech == null ? -1.0 : speech[i]);
    }
    if (f.parsedEnd >= readUntil) return _stopAt(f.parsedEnd);

    // The rest of a file still arriving is a hole.
    if (!f.lifecycle.isTerminal && _waivedUntil(f.key) <= f.parsedEnd) {
      // A boundary made at the end of what was here then still closes what is open.
      _passBoundariesWithin(f.parsedEnd + 1);
      stoppedAt = PlanPosition(f.key, f.parsedEnd);
      return false;
    }
    _passBoundariesWithin(1 << 40);
    if (!f.lifecycle.isTerminal) {
      // Waived: the rest is late audio when it comes, so what is open stops here.
      final at = PlanPosition(f.key, f.parsedEnd);
      _closeConversation(CloseType.wall, DiscardKind.flushNoise, at);
      _closeLatched(CloseType.wall, at);
    }

    _prevPositionMs = _anchorMs + (n - _anchorFrame) * frameMs;
    _prevSilenceMs = _silenceMs;
    _prevPairMs = _pairMs;
    _prevPairUptimeMs = _uptimeMs;
    _prevPolicy = _policy;
    _prevAad = _aad;
    return true;
  }

  /// Whether [f]'s frames are walked: a card's, or a released file's (all owned). A set-
  /// aside file's wait, and a file without its card is a hole.
  static bool _framesHere(PlanFile f) => (f.audio != null && !f.setAside) || f.released;

  /// A hole inside this file at [offset]: boundaries before it still close what is open.
  bool _stopAt(int offset) {
    _passBoundariesWithin(offset + 1);
    stoppedAt = PlanPosition(_file.key, offset);
    return false;
  }

  /// The real time that passed: the uptime's move [moveMs], or the clock's [sinceMs] when
  /// that is not known (null: the file's header did not say the uptime). The clock was set
  /// when its move differs from the uptime's by more than [clockSetToleranceMs] either way:
  /// the Omi's clock is its uptime plus an offset only a set changes, so otherwise the two
  /// move together.
  static ({bool clockSet, int elapsedMs}) _measure(int sinceMs, int? moveMs) => moveMs == null
      ? (clockSet: false, elapsedMs: max(0, sinceMs))
      : (clockSet: (sinceMs - moveMs).abs() > clockSetToleranceMs, elapsedMs: max(0, moveMs));

  /// How far uptime moved from [from] (in full) to a marker's [to], which carries only its
  /// low 32 bits: the forward difference modulo 2^32. No gap between two records comes near
  /// 2^32 ms (49.7 days; the Omi holds about a day and a half of audio), so this is exact,
  /// even when the uptime itself passes 2^32; except that within [_uptimeSlackMs] short of
  /// a whole wrap it is [from] (an estimate: the last exact uptime plus 20 ms a frame)
  /// running a moment ahead of the marker.
  static int _uptimeDelta(int from, int to) {
    final forward = (to - from) & 0xFFFFFFFF;
    return forward > 0x100000000 - _uptimeSlackMs ? forward - 0x100000000 : forward;
  }

  static const _uptimeSlackMs = 60000;

  /// The uptime's move to a marker that carries [marker] (its low 32 bits), and the
  /// marker's uptime in full; both null when the file has not said its uptime.
  ({int? moveMs, int? uptime}) _marker(int marker) {
    if (_uptimeMs == null) return (moveMs: null, uptime: null);
    final moveMs = _uptimeDelta(_uptimeMs!, marker);
    return (moveMs: moveMs, uptime: _uptimeMs! + moveMs);
  }

  /// Applies the boundaries in this file that come before a record at [offset].
  void _beforeRecord(int offset) => _passBoundariesWithin(offset + 1);

  void _passBoundariesWithin(int limit) {
    while (_boundary < _boundaries.length &&
        _boundaries[_boundary].key == _file.key &&
        _boundaries[_boundary].offset < limit) {
      _applyBoundary(_boundaries[_boundary], PlanPosition(_file.key, _boundaries[_boundary].offset));
      _boundary++;
    }
  }

  bool _frameOwned(int i) {
    while (_ownedCursor < _ownedFrames.length && _ownedFrames[_ownedCursor].$2 <= i) {
      _ownedCursor++;
    }
    return _ownedCursor < _ownedFrames.length && _ownedFrames[_ownedCursor].$1 <= i;
  }

  /// Where a close at the record at [offset] of this file happened. Made only for a close:
  /// not once per frame.
  PlanPosition _at(int offset) => PlanPosition(_file.key, offset);

  void _frame(int i, int offset, bool framesHere, double prob) {
    final t = _anchorMs + (i - _anchorFrame) * frameMs;
    final startUptime = _uptimeMs;
    if (_uptimeMs != null) _uptimeMs = _uptimeMs! + frameMs;
    // The cap is reached when the device time since the start has, at this frame's start.
    final capReached = _inPriority && _priorityElapsedMs >= _priorityCapMs;
    if (_inPriority) _priorityElapsedMs += frameMs;
    // Today's rule, kept: a frame is inside a tap's window when the frame before it was.
    final protectedSpeech = _protectedUntil != null && _lastFrameMs <= _protectedUntil!;
    _lastFrameMs = t;
    _silenceMs = 0;
    // The last moment both are known runs on from its own reference (which a priority start
    // with the Omi's clock may have set apart from the stream's time).
    _pairMs += frameMs;
    _startAdjacent = false;
    final owned = _frameOwned(i);

    if (_latch != null) {
      if (!framesHere) return;
      if (owned) {
        if (_latched != null) _closeLatched(CloseType.wall, _at(offset));
        return;
      }
      (_latched ??= _Latched(_latch!)).add(_file.key, i, t, prob);
      return;
    }

    // ---- event layer ----
    _framesSinceSplit++;
    if (capReached && _inPriority) {
      if (_conv != null) {
        _closeConversation(CloseType.priorityCap, DiscardKind.flushNoise, _at(offset), forceSave: true);
      }
      _inPriority = false;
      _floodReset();
    }
    // ---- conversation layer ----
    if (!framesHere) return;
    if (owned) {
      if (_conv != null) _closeConversation(CloseType.wall, DiscardKind.flushNoise, _at(offset));
      return;
    }
    final isSpeech = _aad || _inPriority || protectedSpeech || prob > _policy.speechThreshold;
    // A conversation that starts inside a tap's window keeps all its audio, whatever
    // closed the one before it.
    final conv = _conv ??= _Conversation(_policy, _aad, _derivedFile, _protectedUntil != null && t <= _protectedUntil!);
    conv.addFrame(_file.key, i, t, startUptime);
    if (prob > conv.maxProb) conv.maxProb = prob;
    if (isSpeech) {
      conv.speechFrames++;
      conv.silenceRunMs = 0;
    } else {
      conv.silenceRunMs += frameMs;
    }
    if (_policy.silenceSplitMs > 0 && conv.silenceRunMs >= _policy.silenceSplitMs) {
      _splitOnSilence(_at(offset));
    } else if (!_inPriority && conv.durationMs >= _policy.maxChunkMs) {
      _closeConversation(CloseType.cap, DiscardKind.noiseMaxDuration, _at(offset));
    } else if (conv.durationMs >= dayLimitMs) {
      _closeConversation(CloseType.dayLimit, DiscardKind.flushNoise, _at(offset), forceSave: true);
    }
  }

  void _event(CardEvent ev) {
    final at = PlanPosition(_file.key, ev.offset);
    final id = EventId(_file.key, ev.offset);
    // Whether a marker is owned decides only whether this plan lists it again, and what it
    // may open: a published tap still forces an open conversation around it to be kept,
    // but opens none (the one it opened is published, or closed with no audio). A released
    // file's taps and Priority Recording starts were all owned when the gate released it;
    // its audio is gone, so none is listed again, even after Reprocess all.
    final listed = !input.owned.events.contains(id) && !_file.released;
    final framesHere = _framesHere(_file);
    switch (ev.kind) {
      case CardEventKind.header:
        return; // the file's clock was read from it at the start; a later one changes nothing
      case CardEventKind.tap:
        _clearLatch(at);
        final markerMs = _markerTime(ev);
        _protectedUntil = (ev.hasClock ? ev.utcMs : markerMs) + tapProtectionMs;
        if (framesHere && (listed || _conv != null)) {
          final conv = _conv ??= _Conversation(_policy, _aad, _derivedFile, true);
          conv.forced = true;
          if (listed) conv.markers.add(PlannedMarker(id, markerMs, conv.durationMs, false));
          if (conv.derived && ev.hasClock) conv.calibration ??= (markerMs, conv.durationMs);
        }
      case CardEventKind.stop:
        _closeConversation(CloseType.stop, DiscardKind.flushNoise, at, forceSave: true);
        _setLatch(DiscardKind.afterStop, at);
        _inPriority = false;
        _protectedUntil = null;
        _floodReset();
      case CardEventKind.priorityStart:
        _closeConversation(CloseType.priorityStart, DiscardKind.flushNoise, at, forceSave: true);
        _clearLatch(at);
        final markerMs = ev.hasClock ? ev.utcMs : _nowMs(ev);
        final read = _marker(ev.uptimeMs);
        _inPriority = true;
        _priorityElapsedMs = 0;
        _priorityCapMs = ev.hasClock ? input.caps.capMsAt(markerMs) : input.caps.longestUpTo(markerMs);
        _startAdjacent = true;
        _lastFrameMs = markerMs;
        _silenceMs = 0; // today's processor measured the next gap from the start marker
        _uptimeMs = read.uptime;
        // It is the new reference, time and uptime at one moment (frames run it on): by its own
        // clock, or else, as a resume without one, by the uptime since the last.
        _pairMs = ev.hasClock ? ev.utcMs : _pairMs + (read.moveMs ?? 0);
        _protectedUntil = markerMs + tapProtectionMs;
        _floodReset();
        if (framesHere) {
          // Not forced: every frame of the span is speech, and its stop forces the save.
          _conv = _Conversation(_policy, _aad, _derivedFile, false);
          if (listed) _conv!.markers.add(PlannedMarker(id, markerMs, 0, true));
        }
      case CardEventKind.muteOn:
        _closeConversation(CloseType.muteOn, DiscardKind.flushNoise, at, forceSave: true);
        _setLatch(DiscardKind.muted, at);
        if (_muteOn == null) {
          _muteOn = id;
          _muteStartMs = ev.hasClock ? ev.utcMs : _nowMs(ev);
        }
        _protectedUntil = null;
        _floodReset();
      case CardEventKind.muteOff:
        _endMute(ev.hasClock ? ev.utcMs : _nowMs(ev), at, CloseType.unmute);
      case CardEventKind.resume:
        _resume(ev, at);
    }
  }

  /// A tap's time: its own clock, unless the audio is dated and the two disagree by more
  /// than [tapDriftMs]; then the audio's.
  int _markerTime(CardEvent ev) {
    final now = _nowMs(ev);
    if (!ev.hasClock) return now;
    if (_derivedFile) return ev.utcMs;
    return (ev.utcMs - now).abs() > tapDriftMs ? now : ev.utcMs;
  }

  /// Where the stream is at a marker by the audio's clock: when the next frame starts.
  /// (Today's processor used the last frame, which after a resume is before the gap.)
  int _nowMs(CardEvent ev) => _anchorMs + (ev.frameIndex - _anchorFrame) * frameMs;

  void _resume(CardEvent ev, PlanPosition at) {
    _clearLatch(at);
    // A resume with no clock is dated by uptime since the last moment both were known.
    // (Today's processor paired the last frame's time with the uptime of any resume since,
    // which dates a second resume by the gap of the first.)
    final read = _marker(ev.uptimeMs);
    final moveMs = read.moveMs;
    final resumeMs = ev.hasClock ? ev.utcMs : _pairMs + (moveMs ?? 0);
    // The padding is how far this resume moves the stream on from where it is, so a second
    // resume with no audio between does not pad the first one's silence again (today's
    // processor did). The silence since the last audio, which decides splits, adds the real
    // time since the last moment both time and uptime were known (see _measure), so a clock
    // set either way counts only the time that passed.
    final padMs = max(0, resumeMs - _nowMs(ev));
    final step = _measure(resumeMs - _pairMs, moveMs);
    final clockJump = step.clockSet;
    final int gapMs = _silenceMs + step.elapsedMs;
    final within = _protectedUntil != null && resumeMs <= _protectedUntil!;

    _priorityElapsedMs += moveMs ?? step.elapsedMs;
    final stale = _inPriority && !_startAdjacent && gapMs >= priorityStaleGapMs;
    if (stale) _inPriority = false;
    final splitWorthy = !within && gapMs > max(0, _policy.silenceSplitMs - firmwareHoldMs);
    final wouldSplit = stale || splitWorthy;

    var coalesce = false;
    if (stale) {
      _floodReset();
    } else if (wouldSplit && _aad) {
      if (!_floodActive) {
        if (_framesSinceSplit > 0 && _framesSinceSplit * frameMs < aadFloodFloorMs) {
          if (++_floodCount >= aadFloodRun) _floodActive = true;
        } else {
          _floodCount = 0;
        }
      }
      coalesce = _floodActive;
    }
    if (wouldSplit) _framesSinceSplit = 0;

    if (wouldSplit && !coalesce) {
      _closeConversation(stale ? CloseType.priorityStale : CloseType.resumeGap, DiscardKind.noisePreSplit, at,
          forceSave: stale);
    } else {
      final conv = _conv;
      if (!coalesce && conv != null && conv.hasFrames && padMs > 0 && !clockJump) {
        if (conv.durationMs + padMs >= dayLimitMs) {
          _closeConversation(CloseType.dayLimit, DiscardKind.flushNoise, at, forceSave: true);
        } else {
          conv.addSilence(padMs);
        }
      }
    }
    // The stream is re-anchored here unless the flood guard coalesced the gap; the last
    // moment both time and uptime are known is this one either way, with the silence up to it.
    if (!coalesce) {
      _anchorMs = resumeMs;
      _anchorFrame = ev.frameIndex;
    }
    _pairMs = resumeMs;
    _uptimeMs = read.uptime;
    _silenceMs = gapMs;
  }

  void _floodReset() {
    _floodCount = 0;
    _floodActive = false;
    _framesSinceSplit = 0;
  }

  void _setLatch(DiscardKind kind, PlanPosition at) {
    if (_latch != kind) _closeLatched(CloseType.latchEnd, at);
    _latch = kind;
  }

  void _clearLatch(PlanPosition at) {
    if (_latch == null) return;
    _closeLatched(CloseType.latchEnd, at);
    _latch = null;
  }

  void _closeLatched(CloseType type, PlanPosition at) {
    final run = _latched;
    _latched = null;
    if (run == null || run.frames == 0) return;
    items.add(PlannedDiscard(
      sessionId: sessionId,
      closeType: type,
      closedAt: at,
      kind: run.kind,
      spans: run.spans(),
      startMs: run.startMs,
      endMs: run.endMs,
      audioMs: run.frames * frameMs,
      maxVoiceProb: run.maxProb,
    ));
  }

  /// Ends a muted interval at [endMs]. The frames latched in it, if the latch is still
  /// the mute's, close with it as one item.
  void _endMute(int endMs, PlanPosition at, CloseType type) {
    final run = _latch == DiscardKind.muted ? _latched : null;
    if (run != null) {
      _latched = null;
      _latch = null;
    } else {
      _clearLatch(at);
    }
    final id = _muteOn;
    final start = _muteStartMs;
    _muteOn = null;
    _muteStartMs = null;
    final interval = id != null && start != null && endMs > start && !input.owned.events.contains(id);
    final latched = run != null && run.frames > 0 ? run : null;
    if (!interval && latched == null) return;
    items.add(PlannedDiscard(
      sessionId: sessionId,
      closeType: type,
      closedAt: at,
      kind: DiscardKind.muted,
      spans: latched?.spans() ?? const [],
      startMs: interval ? start : latched!.startMs,
      endMs: interval ? max(endMs, latched?.endMs ?? 0) : latched!.endMs,
      audioMs: (latched?.frames ?? 0) * frameMs,
      maxVoiceProb: latched?.maxProb ?? 0,
      muteOn: interval ? id : null,
    ));
  }

  bool _tooShort(_Conversation c) =>
      !c.aad && c.policy.minSpeechMs > 0 && c.speechFrames * frameMs < c.policy.minSpeechMs && !c.forced;

  void _splitOnSilence(PlanPosition at) {
    final c = _conv!;
    if (c.speechFrames > 0 && !_tooShort(c)) {
      _save(c, CloseType.silence, at);
    } else {
      _discard(c, c.speechFrames > 0 ? DiscardKind.noiseSilenceSplit : DiscardKind.silenceOnly, CloseType.silence, at);
    }
    _conv = null;
  }

  /// Ends the open conversation: saved, or (too little speech) discarded as [noise]. A
  /// conversation with no frames leaves its markers as orphans.
  void _closeConversation(CloseType type, DiscardKind noise, PlanPosition at, {bool forceSave = false}) {
    final c = _conv;
    if (c == null) return;
    _conv = null;
    if (!c.hasFrames) {
      _orphans(c, type, at);
    } else if (!forceSave && !_inPriority && _tooShort(c)) {
      // Priority Recording's audio is kept, whatever closes it while its capture goes on (a
      // Force, a wall, a gap that may hide whole wraps); only its end ends that.
      _discard(c, noise, type, at);
    } else {
      _save(c, type, at);
    }
  }

  void _save(_Conversation c, CloseType type, PlanPosition at) {
    var start = c.startMs!;
    var startUptime = c.startUptimeMs;
    var derived = c.derived;
    final cal = c.calibration;
    if (derived && cal != null) {
      start = cal.$1 - cal.$2;
      startUptime = null;
      derived = false;
    }
    items.add(PlannedRecording(
      sessionId: sessionId,
      closeType: type,
      closedAt: at,
      pieces: List.unmodifiable(c.finishPieces()),
      startMs: start,
      startUptimeSeconds: startUptime == null ? null : startUptime ~/ 1000,
      derivedTime: derived,
      markers: List.unmodifiable(c.markers),
      durationMs: c.durationMs,
      frameCount: c.frames,
      silero: !c.aad,
      manual: c.policy.manual,
    ));
  }

  void _discard(_Conversation c, DiscardKind kind, CloseType type, PlanPosition at) {
    items.add(PlannedDiscard(
      orphans: _asOrphans(c),
      sessionId: sessionId,
      closeType: type,
      closedAt: at,
      kind: kind,
      spans: List.unmodifiable(c.spans()),
      startMs: c.startMs!,
      endMs: c.startMs! + c.durationMs,
      audioMs: c.frames * frameMs,
      maxVoiceProb: c.maxProb,
    ));
  }

  void _orphans(_Conversation c, CloseType type, PlanPosition at) {
    if (c.markers.isEmpty) return;
    items.add(PlannedOrphans(sessionId: sessionId, closeType: type, closedAt: at, markers: _asOrphans(c)));
  }

  /// A conversation's markers as orphans: no audio, so no offset.
  List<PlannedMarker> _asOrphans(_Conversation c) =>
      List.unmodifiable([for (final m in c.markers) PlannedMarker(m.id, m.markerMs, 0, m.highPriority)]);

  OpenConversation? openSummary() {
    final c = _conv;
    if (c == null) return null;
    return OpenConversation(
      sessionId: sessionId,
      startMs: c.startMs,
      durationMs: c.durationMs,
      frameCount: c.frames,
      markerCount: c.markers.length,
      inPriority: _inPriority,
    );
  }
}
