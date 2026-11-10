// The ownership ledger (RECORDINGS_PIPELINE_REDESIGN.md §4): who owns every frame and
// every marker of every logical file. It is the only source of truth for ownership;
// recordings' meta and `discards.jsonl` are what the UI reads, written by the same
// transactions (coordinator.dart). Nothing but a journaled transaction changes it.
//
// Day files (`ledger/<utc-date>.json`, one per day of raw files; files from before the
// Omi's clock was set go under `ledger/session_<id>.json`) hold, per logical file: a
// tombstone if any, the owned frame ranges and markers with their owners, the event
// summary, and, once the gate has released the raw file, its receipt. The stream file
// (`ledger/stream.json`) holds the generation (R3), the user boundary events, the
// Priority Recording cap history and the set-aside list.
//
// Frames are owned by byte range: a range [start, end) owns the frames whose record
// starts in it, in logical offsets. Bytes are the identity sealing fixes (I2), and the
// identity the discard records and the update from earlier builds (§13) already use.
//
// Not switched on yet (see raw_chunks.dart).

import 'dart:convert';
import 'dart:io';

import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/utils/atomic_file.dart';

const int _minValidEpochSeconds = 946684800;

enum OwnerKind {
  /// A published recording, by its reserved name (`<date>/<stem>`).
  recording,

  /// A discard record, by its id.
  discard,

  /// An orphan-marker record (a tap with no audio around it), by its EDL (`<date>/<stem>`).
  orphan,

  /// A derived deletion (a deleted recording or discard): Reprocess all revokes it (R5).
  deletion,
}

/// Who owns a range or a marker.
class Owner {
  final OwnerKind kind;
  final String id;

  const Owner(this.kind, this.id);

  String encode() => '${kind.name}:$id';

  static Owner decode(String s) {
    final i = s.indexOf(':');
    if (i < 0) throw FormatException('not an owner: $s');
    return Owner(OwnerKind.values.byName(s.substring(0, i)), s.substring(i + 1));
  }

  @override
  bool operator ==(Object other) => other is Owner && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => encode();
}

/// The frames whose record starts in [start, end), owned by [owner].
class OwnedRange {
  final int start;
  final int end;
  final Owner owner;

  const OwnedRange(this.start, this.end, this.owner);

  @override
  bool operator ==(Object other) =>
      other is OwnedRange && other.start == start && other.end == end && other.owner == owner;

  @override
  int get hashCode => Object.hash(start, end, owner);

  @override
  String toString() => '[$start,$end)=$owner';
}

/// A source deletion (R5): the whole logical file, chunks still to arrive and copies
/// restored later included. Survives everything, Reprocess all too.
class Tombstone {
  final int atMs;
  final String reason;

  const Tombstone(this.atMs, this.reason);

  Map<String, Object?> toJson() => {'at': atMs, 'reason': reason};

  factory Tombstone.fromJson(Map<String, Object?> j) => Tombstone(j['at']! as int, j['reason']! as String);
}

/// What is kept of a logical file once the gate released its chunks and card (§6): the
/// source metadata and final lifecycle state from its manifest. Its event summary stays
/// in the entry.
class Receipt {
  final int length;
  final SourceLifecycle lifecycle;
  final int? advertisedLength;
  final int? firstSealedAtMs;
  final List<ChunkProvenance> provenance;

  const Receipt({
    required this.length,
    required this.lifecycle,
    required this.advertisedLength,
    required this.firstSealedAtMs,
    required this.provenance,
  });

  Map<String, Object?> toJson() => {
        'length': length,
        'lifecycle': lifecycle.name,
        if (advertisedLength != null) 'advertised': advertisedLength,
        if (firstSealedAtMs != null) 'firstSealed': firstSealedAtMs,
        'provenance': [for (final p in provenance) p.name],
      };

  factory Receipt.fromJson(Map<String, Object?> j) => Receipt(
        length: j['length']! as int,
        lifecycle: SourceLifecycle.values.byName(j['lifecycle']! as String),
        advertisedLength: j['advertised'] as int?,
        firstSealedAtMs: j['firstSealed'] as int?,
        provenance: [for (final p in (j['provenance']! as List).cast<String>()) ChunkProvenance.values.byName(p)],
      );
}

/// Some owner's claim was refused: part of it belongs to someone else.
class LedgerConflict implements Exception {
  final String message;
  LedgerConflict(this.message);
  @override
  String toString() => 'LedgerConflict: $message';
}

/// One logical file's line in the ledger.
class LedgerEntry {
  final RawFileKey key;
  Tombstone? tombstone;

  /// Sorted by start, disjoint; byte-adjacent ranges of one owner are coalesced.
  final List<OwnedRange> frames;

  /// Owned markers by byte offset: taps and Priority Recording starts (in a recording's
  /// EDL or an orphan record), and mute-ons whose muted interval was published.
  final Map<int, Owner> events;

  EventSummary? summary;
  Receipt? receipt;

  LedgerEntry(this.key, {this.tombstone, List<OwnedRange>? frames, Map<int, Owner>? events, this.summary, this.receipt})
      : frames = frames ?? [],
        events = events ?? {};

  /// Whether any frame in [start, end) is owned.
  bool overlaps(int start, int end) => frames.any((r) => r.start < end && start < r.end);

  /// Adds [owner]'s frames and markers. Idempotent: what [owner] already holds is
  /// skipped, so a transaction can be applied again after a crash. Anything held by
  /// another owner is a conflict, and nothing is changed.
  void claim(Owner owner, List<(int, int)> ranges, List<int> markers) {
    final add = <(int, int)>[];
    for (final (start, end) in ranges) {
      if (start >= end) throw LedgerConflict('${key.rel}: empty range [$start,$end) for $owner');
      final overlapping = frames.where((r) => r.start < end && start < r.end).toList();
      if (overlapping.isEmpty) {
        add.add((start, end));
        continue;
      }
      // Applied before: this owner's ranges cover it exactly.
      final covered = overlapping.every((r) => r.owner == owner) && _covers(overlapping, start, end);
      if (!covered) throw LedgerConflict('${key.rel}: [$start,$end) for $owner overlaps $overlapping');
    }
    for (final m in markers) {
      final had = events[m];
      if (had != null && had != owner) throw LedgerConflict('${key.rel}: marker @$m for $owner is owned by $had');
    }
    final next = [...frames, for (final (start, end) in add) OwnedRange(start, end, owner)];
    _normalizeInto(next); // throws, changing nothing, if the claim overlaps itself
    frames
      ..clear()
      ..addAll(next);
    for (final m in markers) {
      events[m] = owner;
    }
  }

  /// Hands [from]'s markers and frames to [to], limiting frames to [ranges] when
  /// supplied. Splits at the requested boundaries; replay is idempotent.
  void transfer(Set<Owner> from, Owner to, {List<(int, int)>? ranges}) {
    final next = <OwnedRange>[];
    for (final r in frames) {
      if (!from.contains(r.owner)) {
        next.add(r);
        continue;
      }
      if (ranges == null) {
        next.add(OwnedRange(r.start, r.end, to));
        continue;
      }
      final cuts = {r.start, r.end};
      for (final (start, end) in ranges) {
        if (r.start < start && start < r.end) cuts.add(start);
        if (r.start < end && end < r.end) cuts.add(end);
      }
      final sorted = cuts.toList()..sort();
      for (var i = 1; i < sorted.length; i++) {
        final start = sorted[i - 1], end = sorted[i];
        final rendered = ranges.any((range) => range.$1 <= start && end <= range.$2);
        next.add(OwnedRange(start, end, rendered ? to : r.owner));
      }
    }
    _normalizeInto(next);
    frames
      ..clear()
      ..addAll(next);
    for (final o in events.keys.toList()) {
      if (from.contains(events[o])) events[o] = to;
    }
  }

  /// Whether [rs] together cover [start, end) with no gap.
  static bool covers(List<OwnedRange> rs, int start, int end) => _covers(rs, start, end);

  static bool _covers(List<OwnedRange> rs, int start, int end) {
    final sorted = [...rs]..sort((a, b) => a.start.compareTo(b.start));
    var at = start;
    for (final r in sorted) {
      if (r.start > at) return false;
      if (r.end > at) at = r.end;
    }
    return at >= end;
  }

  /// Sorts [ranges], refuses overlaps, and coalesces byte-adjacent ranges of one owner.
  void _normalizeInto(List<OwnedRange> ranges) {
    ranges.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].start < ranges[i - 1].end) {
        throw LedgerConflict('${key.rel}: overlapping ranges ${ranges[i - 1]} and ${ranges[i]}');
      }
    }
    for (var i = ranges.length - 1; i > 0; i--) {
      final a = ranges[i - 1], b = ranges[i];
      if (a.end == b.start && a.owner == b.owner) {
        ranges[i - 1] = OwnedRange(a.start, b.end, a.owner);
        ranges.removeAt(i);
      }
    }
  }

  Map<String, Object?> toJson() {
    final sortedEvents = events.keys.toList()..sort();
    return {
      'timerStart': key.timerStart,
      'sessionId': key.sessionId,
      if (tombstone != null) 'tombstone': tombstone!.toJson(),
      'frames': [
        for (final r in frames) [r.start, r.end, r.owner.encode()]
      ],
      'events': [
        for (final o in sortedEvents) [o, events[o]!.encode()]
      ],
      if (summary != null) 'summary': summary!.toJson(),
      if (receipt != null) 'receipt': receipt!.toJson(),
    };
  }

  factory LedgerEntry.fromJson(Map<String, Object?> j) {
    final entry = LedgerEntry(
      RawFileKey(j['timerStart']! as int, j['sessionId'] as int?),
      tombstone: j['tombstone'] == null ? null : Tombstone.fromJson((j['tombstone']! as Map).cast()),
      frames: [
        for (final r in (j['frames']! as List).cast<List<Object?>>())
          OwnedRange(r[0]! as int, r[1]! as int, Owner.decode(r[2]! as String))
      ],
      events: {
        for (final e in (j['events']! as List).cast<List<Object?>>()) e[0]! as int: Owner.decode(e[1]! as String)
      },
      summary: j['summary'] == null ? null : EventSummary.fromJson((j['summary']! as Map).cast()),
      receipt: j['receipt'] == null ? null : Receipt.fromJson((j['receipt']! as Map).cast()),
    );
    entry._normalizeInto(entry.frames);
    return entry;
  }
}

/// The day file a logical file's entry lives in: the UTC date its name carries, or its
/// session before the Omi's clock was set.
String ledgerDayOf(RawFileKey key) {
  if (key.timerStart < _minValidEpochSeconds) return 'session_${key.sessionId}';
  final d = DateTime.fromMillisecondsSinceEpoch(key.timerStart * 1000, isUtc: true);
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// One day file: its entries by the logical file's relative path.
class LedgerDay {
  final String name;
  final Map<String, LedgerEntry> entries;

  LedgerDay(this.name, [Map<String, LedgerEntry>? entries]) : entries = entries ?? {};

  static const version = 1;

  LedgerEntry entryFor(RawFileKey key) => entries.putIfAbsent(key.rel, () => LedgerEntry(key));

  String encode() {
    final rels = entries.keys.toList()..sort();
    return jsonEncode({
      'v': version,
      'files': {for (final rel in rels) rel: entries[rel]!.toJson()},
    });
  }

  factory LedgerDay.decode(String name, String text) {
    final j = jsonDecode(text) as Map<String, Object?>;
    if (j['v'] != version) throw FormatException('ledger day $name: version ${j['v']} is not $version');
    final files = (j['files']! as Map).cast<String, Object?>();
    return LedgerDay(name, {
      for (final e in files.entries) e.key: LedgerEntry.fromJson((e.value! as Map).cast()),
    });
  }
}

/// What the ledger holds for the stream as a whole.
class StreamState {
  /// Advanced by Reprocess all; a job's transaction commits only under the generation it
  /// planned under (R3).
  int generation;

  /// Force and rebuild ends, in the order they were made.
  final List<PlanBoundary> boundaries;

  /// The Priority Recording cap setting over time; empty until the first is recorded.
  final List<({int atMs, int minutes})> caps;

  /// Files set aside after repeated failures.
  final List<RawFileKey> setAside;

  StreamState(
      {this.generation = 0,
      List<PlanBoundary>? boundaries,
      List<({int atMs, int minutes})>? caps,
      List<RawFileKey>? setAside})
      : boundaries = boundaries ?? [],
        caps = caps ?? [],
        setAside = setAside ?? [];

  static const version = 1;

  String encode() => jsonEncode({
        'v': version,
        'generation': generation,
        'boundaries': [
          for (final b in boundaries)
            {'kind': b.kind.name, 'timerStart': b.key.timerStart, 'sessionId': b.key.sessionId, 'offset': b.offset}
        ],
        'caps': [
          for (final c in caps) [c.atMs, c.minutes]
        ],
        'setAside': [
          for (final k in setAside) [k.timerStart, k.sessionId]
        ],
      });

  factory StreamState.decode(String text) {
    final j = jsonDecode(text) as Map<String, Object?>;
    if (j['v'] != version) throw FormatException('ledger stream: version ${j['v']} is not $version');
    return StreamState(
      generation: j['generation']! as int,
      boundaries: [
        for (final b in (j['boundaries']! as List).cast<Map<String, Object?>>())
          PlanBoundary(BoundaryKind.values.byName(b['kind']! as String),
              RawFileKey(b['timerStart']! as int, b['sessionId'] as int?), b['offset']! as int)
      ],
      caps: [for (final c in (j['caps']! as List).cast<List<Object?>>()) (atMs: c[0]! as int, minutes: c[1]! as int)],
      setAside: [
        for (final k in (j['setAside']! as List).cast<List<Object?>>()) RawFileKey(k[0]! as int, k[1] as int?)
      ],
    );
  }
}

/// The ledger's files under the documents directory. Reading is free; writing happens
/// only inside the coordinator's transactions, which serialize it.
class Ledger {
  final String documentsPath;

  Ledger(this.documentsPath);

  Directory get dir => Directory('$documentsPath/ledger');

  File dayFile(String day) => File('${dir.path}/$day.json');

  File get streamFile => File('${dir.path}/stream.json');

  Future<LedgerDay> loadDay(String day) async {
    final file = dayFile(day);
    if (!await file.exists()) return LedgerDay(day);
    return LedgerDay.decode(day, await file.readAsString());
  }

  Future<void> saveDay(LedgerDay day) async {
    await dir.create(recursive: true);
    await AtomicFile.writeString(dayFile(day.name), day.encode());
  }

  Future<StreamState> loadStream() async {
    final file = streamFile;
    if (!await file.exists()) return StreamState();
    return StreamState.decode(await file.readAsString());
  }

  Future<void> saveStream(StreamState state) async {
    await dir.create(recursive: true);
    await AtomicFile.writeString(streamFile, state.encode());
  }

  /// The entries of [keys] that the ledger has.
  Future<Map<RawFileKey, LedgerEntry>> entriesFor(Iterable<RawFileKey> keys) async {
    final byDay = <String, List<RawFileKey>>{};
    for (final k in keys) {
      byDay.putIfAbsent(ledgerDayOf(k), () => []).add(k);
    }
    final out = <RawFileKey, LedgerEntry>{};
    for (final MapEntry(key: day, value: ks) in byDay.entries) {
      final loaded = await loadDay(day);
      for (final k in ks) {
        final e = loaded.entries[k.rel];
        if (e != null) out[k] = e;
      }
    }
    return out;
  }
}

/// What the planner sees of [entries] for [files]: owned frames as index ranges, and
/// owned markers. A tombstoned file is owned whole (R5). A released file's frames are
/// owned whole from its receipt; its markers are owned as the ledger says, like any
/// file's (the gate releases a file whose mute-on is not yet published).
PlanOwnership planOwnershipOf(Map<RawFileKey, LedgerEntry> entries, Iterable<PlanFile> files) {
  final frames = <RawFileKey, List<(int, int)>>{};
  final events = <EventId>{};
  for (final f in files) {
    final e = entries[f.key];
    if (e == null) continue;
    if (e.tombstone != null) {
      if (f.frameCount > 0) frames[f.key] = [(0, f.frameCount)];
      for (final m in f.events) {
        if (m.kind == CardEventKind.tap || m.kind == CardEventKind.priorityStart || m.kind == CardEventKind.muteOn) {
          events.add(EventId(f.key, m.offset));
        }
      }
      continue;
    }
    for (final o in e.events.keys) {
      events.add(EventId(f.key, o));
    }
    if (f.released) continue;
    final offsets = f.frameOffsets!;
    final ranges = <(int, int)>[];
    for (final r in e.frames) {
      final first = _lowerBound(offsets, r.start);
      final end = _lowerBound(offsets, r.end);
      if (first >= end) continue;
      if (ranges.isNotEmpty && ranges.last.$2 == first) {
        ranges[ranges.length - 1] = (ranges.last.$1, end);
      } else {
        ranges.add((first, end));
      }
    }
    if (ranges.isNotEmpty) frames[f.key] = ranges;
  }
  return PlanOwnership(frames: frames, events: events);
}

/// The first index whose value is at least [value].
int _lowerBound(List<int> sorted, int value) {
  var lo = 0, hi = sorted.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid] < value) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// The logical bytes that own frames [first, end) of a file with these records: from the
/// first frame's record to the end of the last one's.
(int, int) byteRangeOf(ParsedRecords records, int first, int end) {
  final last = end - 1;
  return (records.frameOffsets[first], records.frameOffsets[last] + 4 + ((records.frameLengths[last] + 3) & ~3));
}
