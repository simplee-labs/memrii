// Publication, the user actions and the gate interleaved over generated timelines, with
// crashes at any step (RECORDINGS_PIPELINE_REDESIGN.md §6, §7, §12). The oracle keeps its
// own account of what the user deleted, from the archive as it was before each action,
// and reads frames back from the recordings' sidecars and the discard list:
//
// - I1: in the end every frame of a file not deleted at its source is in exactly one
//   recording, or was deleted by the user (a discard deleted or expired);
// - I4: a tombstoned file's frames never reach a recording made after its tombstone, and
//   audio the user deleted never comes back (except through Reprocess all);
// - the gate releases a file only when it is tombstoned or all of it is owned for good,
//   and the planner, reading receipts, plans exactly as it did from the cards;
// - a crash anywhere leaves no journal or staging once recovered;
// - liveness: once everything has arrived, been forced, published and expired, the gate
//   releases every file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/actions.dart';
import 'package:omi/services/raw/archive_files.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';

import 'plan_fixtures.dart';
import 'publish_fixtures.dart';

typedef _Frame = (int, int);

class _Run {
  final int seed;
  final TimelineGen g;
  final World w;
  final List<Bin> bins;
  final PlanPolicy policy;
  final Map<int?, int?> ended;
  OwnershipCoordinator c;
  final pending = <Bin>[];
  int now;

  /// Frames the user deleted (derived deletions), by the oracle's own account.
  final deleted = <_Frame>{};

  /// Files the gate released before a Reprocess all: their recordings went with the
  /// archive, and their audio with the gate.
  final lost = <RawFileKey>{};

  /// For each tombstoned file, the recordings that existed when it was tombstoned.
  final tombstonedAt = <RawFileKey, Set<String>>{};
  int crashes = 0;
  final counts = <String, int>{};

  _Run(this.seed, this.g, this.w, this.bins, this.policy, this.ended, this.now) : c = OwnershipCoordinator(w.docs);

  String get why => 'seed $seed';
  Bin binOf(RawFileKey k) => bins.firstWhere((b) => b.key == k);

  Future<Set<RawFileKey>> tombstoned() async => {
        for (final e in (await ledgerOf(w.docs)).values)
          if (e.tombstone != null) e.key
      };

  /// Every recording's frames, from its sidecar; a frame in two recordings fails.
  Future<Map<_Frame, String>> recorded() async {
    final a = await Archive.read(w.docs);
    final out = <_Frame, String>{};
    for (final e in a.sidecars.entries) {
      for (final (tag, index, _) in e.value) {
        expect(out[(tag, index)], isNull, reason: '$why: frame ($tag, $index) in ${e.key} and ${out[(tag, index)]}');
        out[(tag, index)] = e.key;
      }
    }
    return out;
  }

  /// Every discard record's frames, by id, from its byte ranges and the fixture's own
  /// record of where each frame was written.
  Future<Map<String, Set<_Frame>>> discarded() async {
    final out = <String, Set<_Frame>>{};
    for (final d in (await Archive.read(w.docs)).discards) {
      final frames = out[d['id']! as String] = {};
      for (final MapEntry(key: rel, value: list) in ((d['binRanges'] as Map?) ?? const {}).entries) {
        final b = bins.firstWhere((b) => b.key.rel == rel);
        for (final pair in (list as List).cast<List<Object?>>()) {
          for (var i = 0; i < b.frameCount; i++) {
            final o = b.frameOffsetsWritten[i];
            if (o >= (pair[0]! as int) && o < (pair[1]! as int)) frames.add((frameTag(b.key), i));
          }
        }
      }
    }
    return out;
  }

  /// Runs one step, crashing in it at a random point when [crash]; afterwards the oracle
  /// takes account of discards that went without becoming a recording, and of tombstones.
  Future<void> step(String name, Future<void> Function(bool crash) body,
      {bool crash = false, bool reset = false}) async {
    counts[name] = (counts[name] ?? 0) + 1;
    final before = await discarded();
    final hadTombstones = await tombstoned();
    if (crash) {
      final hook = CrashAt(1 + g.r.nextInt(6));
      c.faultHook = hook.call;
      try {
        await body(true);
      } on Crash {
        crashes++;
        counts['crash in $name'] = (counts['crash in $name'] ?? 0) + 1;
      }
      c = OwnershipCoordinator(w.docs);
      await c.recover();
    } else {
      await body(false);
    }
    c.faultHook = null;
    expect(c.journalFile.existsSync(), isFalse, reason: '$why: $name left a journal');
    final staging = Directory('${w.docs}/processing_temp');
    if (staging.existsSync()) expect(staging.listSync(), isEmpty, reason: '$why: $name left staging');

    final tombs = await tombstoned();
    final audio = (await Archive.read(w.docs)).heard.keys.toSet();
    for (final k in tombs.difference(hadTombstones)) {
      tombstonedAt[k] = audio;
    }
    if (reset) {
      deleted.clear();
      return;
    }
    final after = await discarded();
    final rec = await recorded();
    for (final MapEntry(key: id, value: frames) in before.entries) {
      if (after.containsKey(id)) continue;
      for (final f in frames) {
        final key = bins.firstWhere((b) => frameTag(b.key) == f.$1).key;
        if (!rec.containsKey(f) && !tombs.contains(key)) deleted.add(f);
      }
    }
    for (final f in deleted) {
      expect(rec[f], isNull, reason: '$why: deleted frame $f came back in ${rec[f]}');
    }
  }

  PublishSettings get settings =>
      PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF', opusSidecar: true, maxItemsPerCommit: 1 + g.r.nextInt(4));

  Future<void> publish(bool crash, {bool all = false}) async {
    final hook = crash ? c.faultHook : null;
    final here = w.bins.keys.toSet();
    final missing = [
      for (final b in bins)
        if (!here.contains(b.key)) b.key
    ];
    await w.drain(c,
        policy: policy,
        missing: missing,
        waived: {
          for (final k in missing)
            if (g.chance(40)) k
        },
        endedSessions: ended,
        settings: settings,
        jobFault: hook,
        pick: all ? null : (_) => g.chance(60));
  }

  /// The gate, checked: everything it released was tombstoned or owned for good, and
  /// planning from the receipts is planning from the cards.
  Future<void> gate(bool crash) async {
    final before = await w.planFiles();
    final released = await RawBinGate(c).release();
    final tombs = await tombstoned();
    final rec = await recorded();
    final open = {for (final s in (await discarded()).values) ...s};
    for (final k in released) {
      if (tombs.contains(k)) continue;
      final b = binOf(k);
      for (var i = 0; i < b.frameCount; i++) {
        final f = (frameTag(k), i);
        expect(rec.containsKey(f) || deleted.contains(f), isTrue, reason: '$why: released ${k.stem} frame $i unowned');
        expect(open.contains(f), isFalse, reason: '$why: released ${k.stem} frame $i still in a discard');
      }
    }
    if (released.isEmpty) return;
    final snap = await c.snapshot(bins.map((b) => b.key));
    PlanInput input(List<PlanFile> files) => PlanInput(
          files: files,
          boundaries: snap.stream.boundaries,
          owned: snap.ownershipFor(files),
          policies: PolicyHistory(policy),
          caps: CapHistory.constant(120),
          endedSessions: ended,
        );
    final withCards = plan(input(before));
    final withReceipts = plan(input(await w.planFiles()));
    expect(withReceipts.items, withCards.items, reason: '$why: receipts plan as cards did');
  }

  /// Each session ended where what is here ends.
  List<PlanBoundary> forces() {
    final last = <int?, RawFileKey>{};
    for (final k in w.bins.keys) {
      final had = last[k.sessionId];
      if (had == null || compareKeys(k, had) > 0) last[k.sessionId] = k;
    }
    return [
      for (final k in last.values) PlanBoundary(BoundaryKind.force, k, w.cards[k]!.records.length),
    ];
  }

  Future<void> anyStep() async {
    final crash = g.chance(15);
    final ids = (await discarded()).keys.toList();
    final arrived = w.bins.keys.toList()..sort(compareKeys);
    final dates = {
      for (final k in arrived)
        if (k.timerStart >= 946684800) localDateOf(k.timerStart * 1000),
      ...(await Archive.read(w.docs)).heard.keys.map((p) => p.split('/')[1]),
    }.toList();
    final aside = (await c.ledger.loadStream()).setAside;
    // Each action that applies now, with its weight.
    final choices = <(int, Future<void> Function())>[
      (25, () => step('publish', (crash) => publish(crash), crash: crash)),
      (10, () => step('gate', gate, crash: crash)),
      (
        4,
        () async {
          now += g.pick([3600, 49 * 3600]) * 1000;
          await step('expire', (_) => ArchiveActions(c).expireDiscards(nowMs: now), crash: crash);
        }
      ),
      // Discards are rare between publication and expiry: when there are some, act on them.
      if (ids.isNotEmpty)
        (
          25,
          () async {
            final id = g.pick(ids);
            await step('delete discard', (_) => ArchiveActions(c).deleteDiscards([id]), crash: crash);
          }
        ),
      if (ids.isNotEmpty)
        (
          35,
          () async {
            final pick = {g.pick(ids), if (g.chance(20)) g.pick(ids)}.toList();
            await step('recover', (_) async {
              final r = await ArchiveActions(c)
                  .recoverDiscards(pick, cards: w.cards, newDecoder: FakeOpus.new, settings: settings);
              expect(r.stop, isNot(RecoverStop.failed), reason: why);
            }, crash: crash);
          }
        ),
      if (dates.isNotEmpty)
        (
          3,
          () async {
            final date = g.pick(dates);
            await step('delete day', (_) => ArchiveActions(c).deleteDay(date, nowMs: now), crash: crash);
          }
        ),
      if (arrived.isNotEmpty)
        (
          3,
          () async {
            final key = g.pick(arrived);
            await step('delete file', (_) => ArchiveActions(c).deleteRawFile(key, nowMs: now), crash: crash);
          }
        ),
      if (arrived.isNotEmpty)
        (
          5,
          () async {
            final key = g.pick(arrived);
            await step(aside.contains(key) ? 'try again' : 'set aside',
                (_) => aside.contains(key) ? ArchiveActions(c).tryAgain(key) : ArchiveActions(c).setAside(key),
                crash: crash);
          }
        ),
      (
        2,
        () async {
          final releasedBefore = {
            for (final e in (await ledgerOf(w.docs)).values)
              if (e.receipt != null) e.key
          };
          final generation = (await c.ledger.loadStream()).generation;
          await step('reprocess all', (_) => ArchiveActions(c).reprocessAll(), crash: crash, reset: true);
          // A crash before its journal leaves nothing done; after it, all of it.
          if ((await c.ledger.loadStream()).generation > generation) lost.addAll(releasedBefore);
        }
      ),
      if (pending.isNotEmpty)
        (
          10,
          () async {
            counts['arrive'] = (counts['arrive'] ?? 0) + 1;
            final b = pending.removeAt(g.r.nextInt(pending.length));
            if (g.chance(40) && b.frameOffsetsWritten.length > 2 && !w.bins.containsKey(b.key)) {
              await w.arrive(b, upTo: b.frameOffsetsWritten[b.frameOffsetsWritten.length ~/ 2]);
              pending.add(b);
            } else {
              await w.arrive(b);
            }
          }
        ),
      if (arrived.isNotEmpty)
        (
          8,
          () async {
            final boundary = g.pick(forces());
            await step('force', (_) => ArchiveActions(c).force([boundary]), crash: crash);
          }
        ),
    ];
    var at = g.r.nextInt(choices.fold(0, (n, c) => n + c.$1));
    for (final (weight, run) in choices) {
      if (at < weight) return run();
      at -= weight;
    }
  }

  Future<void> finish() async {
    for (final b in pending) {
      await w.arrive(b);
    }
    pending.clear();
    for (final k in (await c.ledger.loadStream()).setAside) {
      await ArchiveActions(c).tryAgain(k);
    }
    await step('final force', (_) => ArchiveActions(c).force(forces()));
    await step('final publish', (_) => publish(false, all: true));
    now += 10 * 86400 * 1000;
    await step('final expire', (_) => ArchiveActions(c).expireDiscards(nowMs: now));
    await step('final gate', gate);
  }

  Future<void> check() async {
    final tombs = await tombstoned();
    final rec = await recorded();
    expect(await discarded(), isEmpty, reason: '$why: every discard expired');
    for (final b in bins) {
      if (tombs.contains(b.key) || lost.contains(b.key)) continue;
      for (var i = 0; i < b.frameCount; i++) {
        final f = (frameTag(b.key), i);
        expect(rec.containsKey(f) != deleted.contains(f), isTrue,
            reason: '$why: frame $i of ${b.key.stem}: recorded ${rec[f]}, deleted ${deleted.contains(f)}');
      }
    }
    for (final MapEntry(key: k, value: existing) in tombstonedAt.entries) {
      for (final MapEntry(key: f, value: file) in rec.entries) {
        if (f.$1 == frameTag(k)) {
          expect(existing.contains(file), isTrue, reason: '$why: ${k.stem} tombstoned, yet frame $f is in $file');
        }
      }
    }
    expect(await w.store.listKeys(), isEmpty, reason: '$why: the gate released every file in the end');
  }
}

void main() {
  const seeds = int.fromEnvironment('PIPELINE_SEEDS', defaultValue: 40);

  test('actions, the gate and publication interleaved, with crashes', () async {
    final totals = <String, int>{};
    var crashes = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final g = TimelineGen(9000 + seed);
      final bins = g.timeline();
      final root = Directory.systemTemp.createTempSync('actions_props_');
      try {
        final w = World(root);
        // Automatic modes: manual mode makes no discards to delete or recover.
        final run = _Run(seed, g, w, bins, g.pick([genShort, autoPolicy]), endedOf(bins),
            bins.map((b) => b.clockMs).reduce((a, b) => a > b ? a : b) + 3600 * 1000);
        for (final b in bins) {
          if (g.chance(60)) {
            await w.arrive(b);
          } else {
            run.pending.add(b);
          }
        }
        for (var i = 0; i < 30; i++) {
          await run.anyStep();
        }
        await run.finish();
        await run.check();
        crashes += run.crashes;
        run.counts.forEach((k, v) => totals[k] = (totals[k] ?? 0) + v);
      } finally {
        root.deleteSync(recursive: true);
      }
    }
    // Every action ran, and crashed, somewhere.
    for (final name in [
      'publish',
      'gate',
      'delete discard',
      'expire',
      'recover',
      'delete day',
      'delete file',
      'force'
    ]) {
      expect(totals[name] ?? 0, greaterThan(0), reason: '$name never ran: $totals');
    }
    expect(crashes, greaterThan(seeds ~/ 2), reason: '$totals');
    // ignore: avoid_print
    print('$crashes crashes; $totals');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
