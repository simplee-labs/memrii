// Property tests on the planner over generated timelines (RECORDINGS_PIPELINE_REDESIGN.md
// §12): files of several sessions with every marker kind, gaps, clock jumps (some by about
// a whole 32-bit uptime wrap; no gap is that long), undecodable frames, several
// policies and switches between them, files set aside, missing, given up on or still
// arriving (at a session's end or before later files), and Force.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';

import 'plan_fixtures.dart';

const _short = PlanPolicy(
    vadEnabled: true,
    speechThreshold: 0.5,
    silenceSplitMs: 30000,
    minSpeechMs: 3000,
    maxChunkMs: 1 << 62,
    manual: false);
const _capped = PlanPolicy(
    vadEnabled: true, speechThreshold: 0.5, silenceSplitMs: 30000, minSpeechMs: 2000, maxChunkMs: 90000, manual: false);
const _policies = [autoPolicy, _short, _capped, manualPolicy];

class _Scenario {
  final List<Bin> bins;
  final PlanInput input;
  _Scenario(this.bins, this.input);
}

class _Gen {
  final Random r;
  _Gen(int seed) : r = Random(seed);

  T pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];
  bool chance(int percent) => r.nextInt(100) < percent;

  List<Bin> timeline() {
    final bins = <Bin>[];
    var t = 1789000000000 + r.nextInt(100000) * 1000;
    final sessions = 1 + r.nextInt(3);
    for (var s = 0; s < sessions; s++) {
      var b = Bin(t, session: 100 + s, uptimeMs: 10000 + r.nextInt(100000));
      final files = 1 + r.nextInt(4);
      for (var f = 0; f < files; f++) {
        if (f > 0) {
          // The Omi names a file by its start second; two never share one.
          final prev = b.key.timerStart;
          b = b.next(gapMs: pick([0, 0, 0, 4000, 20000, 60000, 200000]) + r.nextInt(1000));
          if (b.key.timerStart == prev) {
            b = Bin((prev + 1) * 1000, session: b.key.sessionId!, uptimeMs: b.uptimeMs + 1000);
          }
        }
        _ops(b);
        bins.add(b);
      }
      t = b.clockMs + 600000 + r.nextInt(100000) * 10;
    }
    return bins;
  }

  void _ops(Bin b) {
    final n = 2 + r.nextInt(14);
    for (var i = 0; i < n; i++) {
      final k = r.nextInt(100);
      if (k < 45) {
        b.frames(1 + r.nextInt(chance(50) ? 60 : 2500),
            p: pick([speech, speech, quiet, quiet, -1.0, 0.6, 0.4]), decoded: !chance(5));
      } else if (k < 63) {
        if (chance(6)) {
          // The clock set by about a whole uptime wrap (no sleep is that long: the Omi holds
          // about a day and a half of audio).
          b.resume(0x100000000 + pick([-30000, -10, 1000, 50000]), clockSet: true, elapsedMs: pick([-10, 0, 2000]));
        } else {
          b.resume(pick([300, 2000, 16000, 25000, 60000, 100000, 130000, 400000]) + r.nextInt(999),
              clockSet: chance(8), clockless: chance(8));
        }
      } else if (k < 74) {
        b.tap(atMs: chance(8) ? 0 : (chance(8) ? b.clockMs + 300000 : null));
      } else if (k < 81) {
        b.stop();
      } else if (k < 88) {
        b.priority();
      } else if (k < 94) {
        b.muteOn();
      } else {
        b.muteOff();
      }
    }
  }

  PolicyHistory policies(List<Bin> bins) {
    final current = pick(_policies);
    if (!chance(35)) return PolicyHistory(current);
    final at = pick(bins).key.timerStart;
    return PolicyHistory(current, [(atUtcSeconds: at, before: pick(_policies))]);
  }

  /// Any input: files missing, given up on, set aside, still arriving, Force anywhere.
  _Scenario any() {
    final bins = timeline();
    final files = <PlanFile>[];
    final missing = <RawFileKey>[];
    final waived = <RawFileKey>{};
    final boundaries = <PlanBoundary>[];
    for (var i = 0; i < bins.length; i++) {
      final b = bins[i];
      final last = i == bins.length - 1 || bins[i + 1].key.sessionId != b.key.sessionId;
      if (chance(8)) {
        missing.add(b.key);
        if (chance(50)) waived.add(b.key);
        continue;
      }
      files.add(b.file(
        hasVad: !chance(10),
        setAside: chance(5),
        withAudio: !chance(4),
        // A download that failed part-way leaves a file still arriving before later ones.
        lifecycle: chance(last ? 25 : 5) ? SourceLifecycle.receiving : SourceLifecycle.complete,
      ));
      if (chance(25)) boundaries.add(forceInside(b));
    }
    return _Scenario(
        bins,
        PlanInput(
          files: files,
          missing: missing,
          waived: waived,
          boundaries: boundaries,
          policies: policies(bins),
          caps: CapHistory.constant(pick([0, 1, 120])),
          endedSessions: _ended(bins),
        ));
  }

  /// Force somewhere in [b]: at a record, or at its end (where it was when Force came).
  PlanBoundary forceInside(Bin b) {
    final f = b.file();
    final offsets = [...f.frameOffsets!, for (final e in f.events) e.offset, f.parsedEnd];
    return PlanBoundary(chance(15) ? BoundaryKind.rebuildEnd : BoundaryKind.force, b.key, pick(offsets));
  }

  /// Everything here, finished: each session ends in Force, after Forces anywhere earlier.
  /// A session's last file may still be arriving: its Force is at the end of what came.
  _Scenario drained() {
    final bins = timeline();
    final boundaries = <PlanBoundary>[];
    final files = <PlanFile>[];
    for (var i = 0; i < bins.length; i++) {
      final last = i == bins.length - 1 || bins[i + 1].key.sessionId != bins[i].key.sessionId;
      if (chance(15)) boundaries.add(forceInside(bins[i]));
      if (last) boundaries.add(bins[i].force);
      files.add(bins[i].file(
          hasVad: !chance(10), lifecycle: last && chance(25) ? SourceLifecycle.receiving : SourceLifecycle.complete));
    }
    return _Scenario(
        bins,
        PlanInput(
          files: files,
          boundaries: boundaries,
          policies: policies(bins),
          caps: CapHistory.constant(pick([0, 1, 120])),
          endedSessions: _ended(bins),
        ));
  }
}

/// What the Omi's session ids say, from every file it wrote, whether here or not.
Map<int?, int?> _ended(List<Bin> bins) =>
    endedSessionsOf([for (final b in bins) (key: b.key, startMs: b.file().header!.utcMs)]);

PlanInput _with(PlanInput i, {PlanOwnership? owned, List<PlanFile>? files, List<RawFileKey>? missing}) => PlanInput(
      files: files ?? i.files,
      missing: missing ?? i.missing,
      waived: i.waived,
      boundaries: i.boundaries,
      owned: owned ?? i.owned,
      policies: i.policies,
      caps: i.caps,
      endedSessions: i.endedSessions,
    );

String _open(Plan p) => [
      for (final o in p.open)
        '${o.sessionId}:${o.startMs}+${o.durationMs}/${o.frameCount}/${o.markerCount}/${o.inPriority}'
    ].join(' ');

void main() {
  const seeds = 150;

  test('I8: publishing any closed items leaves the plan of everything else unchanged', () {
    var checked = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(seed);
      final s = g.any();
      final full = plan(s.input);
      for (var round = 0; round < 3 && full.items.isNotEmpty; round++) {
        final published = <int>{};
        if (round == 0) {
          published.addAll(List.generate(1 + g.r.nextInt(full.items.length), (i) => i)); // a prefix
        } else {
          for (var i = 0; i < full.items.length; i++) {
            if (g.chance(50)) published.add(i);
          }
        }
        final again = plan(_with(s.input, owned: ownershipOf([for (final i in published) full.items[i]])));
        expect(
            again.items,
            [
              for (var i = 0; i < full.items.length; i++)
                if (!published.contains(i)) full.items[i]
            ],
            reason: 'seed $seed round $round');
        expect(_open(again), _open(full), reason: 'seed $seed round $round');
        expect(again.stoppedAt, full.stoppedAt, reason: 'seed $seed round $round');
        checked++;
      }
    }
    expect(checked, greaterThan(seeds));
  });

  test('interrupted publication, in any batches, ends with exactly the continuous plan', () {
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(1000 + seed);
      final s = g.any();
      final full = plan(s.input);
      final published = <PlanItem>[];
      for (var round = 0; round < 100; round++) {
        final p = plan(_with(s.input, owned: ownershipOf(published)));
        if (p.items.isEmpty) break;
        final batch = [
          for (final item in p.items)
            if (g.chance(40)) item
        ];
        published.addAll(batch.isEmpty ? [p.items.first] : batch);
      }
      expect(published.length, full.items.length, reason: 'seed $seed');
      for (final item in full.items) {
        expect(published, contains(item), reason: 'seed $seed');
      }
    }
  });

  test('I1: drained, every frame and every tap has exactly one owner', () {
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(2000 + seed);
      final s = g.drained();
      final p = plan(s.input);
      expect(p.open, isEmpty, reason: 'seed $seed');
      final owned = ownershipOf(p.items); // throws on any frame owned twice
      for (final f in s.input.files) {
        final ranges = owned.frames[f.key] ?? const [];
        var covered = 0;
        for (final (first, end) in ranges) {
          covered += end - first;
        }
        expect(covered, f.frameCount, reason: 'seed $seed: frames of ${f.key.stem}');
        final markers = f.events
            .where((e) => e.kind == CardEventKind.tap || e.kind == CardEventKind.priorityStart)
            .map((e) => EventId(f.key, e.offset));
        for (final m in markers) {
          final owners = p.items.where((i) => i.events.contains(m)).length;
          expect(owners, 1, reason: 'seed $seed: marker $m');
        }
      }
    }
  });

  test('Priority Recording: frames between a start and its stop are recordings, never discards', () {
    // Spans with only frames and taps between start and stop, inside one file and short of
    // the cap: nothing there may end the capture, whatever else closes its recordings.
    var spans = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(8000 + seed);
      final s = g.drained();
      final p = plan(s.input);
      final kept = ownershipOf(p.items.whereType<PlannedRecording>());
      for (final f in s.input.files) {
        final events = f.events;
        for (var i = 0; i < events.length; i++) {
          if (events[i].kind != CardEventKind.priorityStart) continue;
          var j = i + 1;
          while (j < events.length && events[j].kind == CardEventKind.tap) {
            j++;
          }
          if (j == events.length || events[j].kind != CardEventKind.stop) continue;
          final first = events[i].frameIndex, end = events[j].frameIndex;
          if ((end - first) * frameMs >= s.input.caps.capMsAt(events[i].utcMs)) continue;
          spans++;
          for (var k = first; k < end; k++) {
            expect((kept.frames[f.key] ?? const []).any((r) => r.$1 <= k && k < r.$2), isTrue,
                reason: 'seed $seed: ${f.key.stem} frame $k of the span from ${events[i].offset}');
          }
        }
      }
    }
    expect(spans, greaterThan(seeds ~/ 10), reason: 'the property has spans to check');
  });

  test('I1 under any order of arrival and publication: each frame and tap ends with one owner', () {
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(5000 + seed);
      final s = g.drained();
      final all = s.input.files;
      final order = [...all]..shuffle(g.r);
      final published = <PlanItem>[];
      // The gate releases a file once all of it is owned: from then on only its receipt.
      final released = <RawFileKey>{};
      List<PlanFile> asTheGateLeftThem(List<PlanFile> here) {
        final owned = ownershipOf(published);
        for (final f in here) {
          if (g.chance(70) && releasable(f, owned)) released.add(f.key);
        }
        return [for (final f in here) released.contains(f.key) ? receiptOf(f) : f];
      }

      PlanInput at(List<PlanFile> here, List<PlanBoundary> boundaries, Set<RawFileKey> waived) => PlanInput(
            files: asTheGateLeftThem(here),
            missing: [
              for (final f in all)
                if (!here.contains(f)) f.key
            ],
            waived: waived,
            boundaries: boundaries,
            owned: ownershipOf(published),
            policies: s.input.policies,
            caps: s.input.caps,
            endedSessions: s.input.endedSessions,
          );
      // Files arrive one at a time; some missing ones are given up on, so late audio
      // lands between published items; each plan publishes some of what closed.
      for (var n = 1; n <= order.length; n++) {
        final here = order.take(n).toList();
        final waived = {
          for (final f in all)
            if (!here.contains(f) && g.chance(50)) f.key
        };
        final p = plan(at(here, const [], waived));
        published.addAll([
          for (final item in p.items)
            if (g.chance(60)) item
        ]);
      }
      // Then everything is here, and Force finishes it.
      for (var round = 0; round < 100; round++) {
        final p = plan(at(all, s.input.boundaries, const {}));
        if (p.items.isEmpty) break;
        published.addAll(p.items);
      }
      final owned = ownershipOf(published); // throws on any frame owned twice
      for (final f in all) {
        final covered = (owned.frames[f.key] ?? const []).fold<int>(0, (n, r) => n + r.$2 - r.$1);
        expect(covered, f.frameCount, reason: 'seed $seed: frames of ${f.key.stem}');
        for (final e in f.events.where((e) => e.kind == CardEventKind.tap || e.kind == CardEventKind.priorityStart)) {
          final id = EventId(f.key, e.offset);
          expect(published.where((i) => i.events.contains(id)).length, 1, reason: 'seed $seed: marker $id');
        }
      }
    }
  });

  test('releasing a file changes nothing: its receipt plans as its card did, all owned', () {
    var released = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(6000 + seed);
      final s = g.any();
      final full = plan(s.input);
      if (full.items.isEmpty) continue;
      // Most often everything that closed: a file is releasable only when all of it is.
      final everything = g.chance(60);
      final published = [
        for (final item in full.items)
          if (everything || g.chance(70)) item
      ];
      final owned = ownershipOf(published);
      final withCards = plan(_with(s.input, owned: owned));
      final files = [
        for (final f in s.input.files)
          if (releasable(f, owned) && g.chance(80)) receiptOf(f) else f
      ];
      released += files.where((f) => f.released).length;
      final withReceipts = plan(_with(s.input, owned: owned, files: files));
      expect(withReceipts.items, withCards.items, reason: 'seed $seed');
      expect(_open(withReceipts), _open(withCards), reason: 'seed $seed');
      expect(withReceipts.stoppedAt, withCards.stoppedAt, reason: 'seed $seed');
    }
    expect(released, greaterThan(seeds), reason: 'the property releases files');
  });

  test('R2: nothing closes on evidence from beyond a hole', () {
    var checked = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(3000 + seed);
      final bins = g.timeline();
      final input = PlanInput(
        files: [for (final b in bins) b.file(hasVad: !g.chance(10))],
        policies: g.policies(bins),
        caps: CapHistory.constant(g.pick([0, 1, 120])),
        endedSessions: _ended(bins),
      );
      // Any file, a session's first included: which sessions ended is the Omi's evidence,
      // not something read from the files.
      final hole = g.pick(bins).key;
      final full = plan(input);
      final holed = plan(_with(input, files: input.files.where((f) => f.key != hole).toList(), missing: [hole]));
      final at = PlanPosition(hole, -1);
      expect(
          holed.items, full.items.where((i) => i.sessionId != hole.sessionId || i.closedAt.compareTo(at) < 0).toList(),
          reason: 'seed $seed');
      for (final item in holed.items.where((i) => i.sessionId == hole.sessionId)) {
        for (final span in item.spans) {
          expect(compareKeys(span.key, hole), lessThan(0), reason: 'seed $seed');
        }
      }
      checked++;
    }
    expect(checked, greaterThan(seeds ~/ 3));
  });

  test('growth: what closed before the end of a file still arriving is what its whole closes there', () {
    var checked = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(7000 + seed);
      final bins = g.timeline();
      final files = [for (final b in bins) b.file(hasVad: !g.chance(10))];
      final input = PlanInput(
        files: files,
        policies: g.policies(bins),
        caps: CapHistory.constant(g.pick([0, 1, 120])),
        endedSessions: _ended(bins),
      );
      // Any file, later files of its session here or not, cut at any record.
      final i = g.r.nextInt(bins.length);
      final whole = files[i];
      final cuts = [...whole.frameOffsets!, for (final e in whole.events) e.offset, whole.parsedEnd];
      final cut = g.pick(cuts);
      final records = parseRecords(Uint8List.sublistView(bins[i].bytes, 0, cut));
      final n = records.frameCount;
      final prefix = PlanFile(
        key: whole.key,
        records: records,
        audio: FrameAudio(
            decoded: Uint8List.sublistView(whole.audio!.decoded, 0, n),
            speech: Float32List.sublistView(whole.audio!.speech, 0, n)),
        hasVad: whole.hasVad,
        lifecycle: SourceLifecycle.receiving,
      );
      final full = plan(input);
      final growing = plan(_with(input, files: [for (final f in files) f == whole ? prefix : f]));
      final at = PlanPosition(whole.key, cut);
      expect(growing.items,
          full.items.where((it) => it.sessionId != whole.key.sessionId || it.closedAt.compareTo(at) < 0).toList(),
          reason: 'seed $seed');
      checked++;
    }
    expect(checked, seeds);
  });

  test('arrival order: with nothing published, the order files are given in changes nothing', () {
    for (var seed = 0; seed < seeds; seed++) {
      final g = _Gen(4000 + seed);
      final s = g.any();
      final shuffled = [...s.input.files]..shuffle(g.r);
      final a = plan(s.input);
      final b = plan(_with(s.input, files: shuffled));
      expect(b.items, a.items, reason: 'seed $seed');
      expect(_open(b), _open(a), reason: 'seed $seed');
    }
  });
}
