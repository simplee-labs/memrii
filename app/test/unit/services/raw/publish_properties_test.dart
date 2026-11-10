// Publication end to end over generated timelines (RECORDINGS_PIPELINE_REDESIGN.md §12):
// sealed files on disk, the planner, the job, the coordinator and the ledger, with a fake
// decoder whose samples name their frame. The oracle reads the archive back: the audio
// heard, the sidecars, the discard list, the EDLs and the ledger's day files.
//
// - Publication is faithful: drained in batches of any size, the archive is exactly the
//   continuous plan, frame for frame, silence for silence.
// - A crash at any step, recovered from disk alone (once, or again inside recovery),
//   ends with the very same archive and ledger.
// - Files arriving in any order, some in two parts, with publication between: every frame
//   and every tap ends with exactly one owner.

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/raw/render.dart';

import 'plan_fixtures.dart';
import 'publish_fixtures.dart';

/// The byte ranges the oracle expects for [spans], from the offsets the fixture wrote.
Map<String, List<List<int>>> _expectedRanges(List<FrameSpan> spans, Map<RawFileKey, Bin> bins) {
  final out = <String, List<List<int>>>{};
  for (final s in spans) {
    if (s.length == 0) continue;
    final offs = bins[s.key]!.frameOffsetsWritten;
    final list = out.putIfAbsent(s.key.rel, () => []);
    final start = offs[s.first], end = offs[s.end - 1] + 12;
    if (list.isNotEmpty && list.last[1] == start) {
      list.last[1] = end;
    } else {
      list.add([start, end]);
    }
  }
  return out;
}

/// What the oracle expects to hear in [r]: each decodable frame with the silence before
/// it, and the silence after the last.
(List<(FrameName, int, int)>, int) _expectedHeard(PlannedRecording r, Map<RawFileKey, Bin> bins) {
  final out = <(FrameName, int, int)>[];
  var silence = 0;
  for (final p in r.pieces) {
    switch (p) {
      case SilencePiece(:final ms):
        silence += ms * 16;
      case FramesPiece(:final span):
        final b = bins[span.key]!;
        for (var i = span.first; i < span.end; i++) {
          if (b.decodable[i] == 0) {
            silence += samplesPerFrame;
            continue;
          }
          out.add(((frameTag(span.key), i), silence, i));
          silence = 0;
        }
    }
  }
  return (out, silence);
}

String _heardKey(List<(FrameName, int, int)> heard, int trailing) => '${heard.join(',')}|$trailing';

/// The archive is exactly [p]'s closed items.
Future<void> _expectArchiveIs(Plan p, World w, String reason) async {
  final a = await Archive.read(w.docs);
  // Recordings: matched by what they hold.
  final byHeard = <String, List<String>>{};
  for (final rel in a.heard.keys) {
    byHeard.putIfAbsent(_heardKey(a.heard[rel]!, a.trailingSilence[rel]!), () => []).add(rel);
  }
  final fileOf = <PlannedRecording, String>{};
  final recordings = p.items.whereType<PlannedRecording>().toList();
  expect(a.heard.length, recordings.length, reason: '$reason: recordings');
  for (final r in recordings) {
    final (heard, trailing) = _expectedHeard(r, w.bins);
    final match = byHeard[_heardKey(heard, trailing)];
    expect(match, isNotNull, reason: '$reason: no recording holds $r');
    final rel = match!.removeAt(0);
    if (match.isEmpty) byHeard.remove(_heardKey(heard, trailing));
    fileOf[r] = rel;
    final name = rel.split('/').last;
    final ms = int.parse(name.split('.').first.split('_').last);
    expect(ms - r.startMs, inInclusiveRange(0, 50), reason: '$reason: $name for a start at ${r.startMs}');
    expect(name.startsWith(r.derivedTime ? 'unknown_' : 'recording_'), isTrue, reason: reason);
    expect(a.samples[rel], r.durationMs * 16, reason: '$reason: $name length');
    final conv = Conversation.fromFile(File('${w.docs}/$rel'));
    expect(conv.duration.inMilliseconds, r.durationMs, reason: '$reason: $name meta duration');
    expect(conv.sessionId, r.sessionId ?? 0, reason: reason);
    expect(conv.startUptime, r.startUptimeSeconds == null ? 0 : max(1, r.startUptimeSeconds!), reason: reason);
    expect(conv.forceSynced, r.closeType == CloseType.force, reason: '$reason: $name bolt');
    expect(conv.capEnded, r.closeType == CloseType.cap || r.closeType == CloseType.dayLimit, reason: reason);
    expect(conv.isSilero, r.silero, reason: reason);
    expect(conv.recordedManual, r.manual, reason: reason);
    expect(conv.uploadKey, 'AABBCC_recording_$ms.${name.split('.').last}', reason: reason);
    expect(
        conv.relativeBins,
        [
          for (final k in {for (final s in r.spans) s.key}) k.rel
        ]..sort(),
        reason: reason);
    // The sidecar holds every frame, decodable or not, in order.
    expect(
        a.sidecars[rel],
        [
          for (final s in r.spans)
            for (var i = s.first; i < s.end; i++) (frameTag(s.key), i, w.bins[s.key]!.decodable[i] == 1)
        ],
        reason: '$reason: sidecar of $name');
  }
  // Discards: their reason and exact byte ranges.
  final discards = p.items.whereType<PlannedDiscard>().toList();
  expect(a.discards.length, discards.length, reason: '$reason: discards');
  final records = [for (final d in a.discards) '${d['reason']} ${d['binRanges']} ${d['startMs']}-${d['endMs']}']
    ..sort();
  final expected = [
    for (final d in discards) '${d.kind.reason} ${_expectedRanges(d.spans, w.bins)} ${d.startMs}-${d.endMs}'
  ]..sort();
  expect(records, expected, reason: '$reason: discard records');
  // EDLs: each marker once, in its recording or as an orphan.
  final edls = [
    for (final e in a.edls)
      '${e['markerTimestampMs']} ${e['segmentFilename']} ${e['markerOffsetMs']} ${e['isHighPriority']}'
  ]..sort();
  final markers = [
    for (final r in recordings)
      for (final m in r.markers) '${m.markerMs} ${fileOf[r]!.split('/').last} ${m.offsetMs} ${m.highPriority}',
    for (final i in p.items)
      for (final m in switch (i) {
        PlannedOrphans(:final markers) => markers,
        PlannedDiscard(:final orphans) => orphans,
        _ => const <PlannedMarker>[],
      })
        '${m.markerMs}  0 ${m.highPriority}',
  ]..sort();
  expect(edls, markers, reason: '$reason: EDLs');
}

/// I1 by the oracle: every frame in exactly one recording's sidecar or one discard's
/// ranges; every tap and Priority Recording start owned once in the ledger and in exactly
/// one EDL; the ledger covering every frame once.
Future<void> _expectEveryFrameOwnedOnce(World w, String reason) async {
  final a = await Archive.read(w.docs);
  final seen = <(int, int), String>{};
  void own((int, int) frame, String by) {
    expect(seen[frame], isNull, reason: '$reason: frame $frame in $by and ${seen[frame]}');
    seen[frame] = by;
  }

  for (final e in a.sidecars.entries) {
    for (final (tag, index, _) in e.value) {
      own((tag, index), e.key);
    }
    // What is heard is exactly the sidecar's decodable frames.
    expect([
      for (final h in a.heard[e.key]!) h.$1
    ], [
      for (final (tag, index, ok) in e.value)
        if (ok) (tag, index)
    ], reason: '$reason: ${e.key}');
  }
  for (final d in a.discards) {
    final ranges = (d['binRanges']! as Map).cast<String, Object?>();
    for (final MapEntry(key: rel, value: list) in ranges.entries) {
      final bin = w.bins.values.firstWhere((b) => b.key.rel == rel);
      for (final pair in (list! as List).cast<List<Object?>>()) {
        for (var i = 0; i < bin.frameCount; i++) {
          final o = bin.frameOffsetsWritten[i];
          if (o >= (pair[0]! as int) && o < (pair[1]! as int)) own((frameTag(bin.key), i), 'discard ${d['id']}');
        }
      }
    }
  }
  for (final b in w.bins.values) {
    for (var i = 0; i < b.frameCount; i++) {
      expect(seen.containsKey((frameTag(b.key), i)), isTrue, reason: '$reason: frame $i of ${b.key.stem} has no owner');
    }
  }
  final ledger = await ledgerOf(w.docs);
  var markers = 0;
  for (final b in w.bins.values) {
    final entry = ledger[b.key] ?? LedgerEntry(b.key);
    var covered = 0;
    for (final r in entry.frames) {
      covered += b.frameOffsetsWritten.where((o) => o >= r.start && o < r.end).length;
    }
    expect(covered, b.frameCount, reason: '$reason: ledger frames of ${b.key.stem}');
    for (final e in parseRecords(b.bytes).events) {
      if (e.kind != CardEventKind.tap && e.kind != CardEventKind.priorityStart) continue;
      markers++;
      expect(entry.events.containsKey(e.offset), isTrue, reason: '$reason: marker ${b.key.stem}@${e.offset}');
    }
  }
  expect(a.edls.length, markers, reason: '$reason: one EDL per marker');
}

Future<World> _world(Directory root, List<Bin> bins, TimelineGen g) async {
  final w = World(root);
  for (final b in bins) {
    await w.arrive(b, hasVad: !g.chance(10));
  }
  return w;
}

void main() {
  const seeds = int.fromEnvironment('PIPELINE_SEEDS', defaultValue: 40);

  test('drained in batches of any size, the archive is exactly the continuous plan', () async {
    var items = 0;
    for (var seed = 0; seed < seeds; seed++) {
      final g = TimelineGen(seed);
      final bins = g.timeline();
      final root = Directory.systemTemp.createTempSync('publish_');
      try {
        final w = await _world(root, bins, g);
        final boundaries = g.forces(bins);
        final policy = g.pick(genPolicies);
        final files = await w.planFiles();
        final full = plan(PlanInput(
          files: files,
          boundaries: boundaries,
          policies: PolicyHistory(policy),
          caps: CapHistory.constant(120),
          endedSessions: endedOf(bins),
        ));
        expect(full.open, isEmpty, reason: 'seed $seed');
        items += full.items.length;
        final last = await w.drain(OwnershipCoordinator(root.path),
            policy: policy, boundaries: boundaries, endedSessions: endedOf(bins), settings: g.settings());
        expect(last.items, isEmpty);
        await _expectArchiveIs(full, w, 'seed $seed');
        await _expectEveryFrameOwnedOnce(w, 'seed $seed');
      } finally {
        root.deleteSync(recursive: true);
      }
    }
    expect(items, greaterThan(seeds * 2));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a crash at any step, recovered from disk alone, ends with the same archive and ledger', () async {
    var crashes = 0;
    for (var seed = 0; seed < seeds ~/ 2; seed++) {
      final g = TimelineGen(100 + seed);
      final bins = g.timeline();
      final boundaries = g.forces(bins);
      final policy = g.pick(genPolicies);
      final settings = g.settings();
      final m4a = g.chance(30);
      final ended = endedOf(bins);

      Future<void> run(World w, OwnershipCoordinator c, void Function(String)? fault) async {
        c.faultHook = fault;
        await w.drain(c,
            policy: policy,
            boundaries: boundaries,
            endedSessions: ended,
            jobFault: fault,
            encoder: m4a ? FakeEncoder() : null,
            settings: PublishSettings(
                deviceId: settings.deviceId,
                opusSidecar: true,
                m4a: m4a,
                maxItemsPerCommit: settings.maxItemsPerCommit,
                maxAudioMsPerCommit: settings.maxAudioMsPerCommit));
      }

      // The run without a crash, counting the points a crash could interrupt.
      final cleanRoot = Directory.systemTemp.createTempSync('publish_clean_');
      late Map<String, String> clean;
      final counter = CrashAt(1 << 30);
      try {
        final w = await _world(cleanRoot, bins, TimelineGen(100 + seed));
        await run(w, OwnershipCoordinator(cleanRoot.path), counter.call);
        clean = await treeOf(cleanRoot.path, ['recordings', 'ledger']);
      } finally {
        cleanRoot.deleteSync(recursive: true);
      }
      final points = counter.seen;
      final at = {for (var i = 0; i < min(points, 8); i++) 1 + g.r.nextInt(points)};
      for (final k in at) {
        for (final twice in [false, true]) {
          final root = Directory.systemTemp.createTempSync('publish_crash_');
          try {
            final w = await _world(root, bins, TimelineGen(100 + seed));
            final crash = CrashAt(k);
            await expectLater(run(w, OwnershipCoordinator(root.path), crash.call), throwsA(isA<Crash>()),
                reason: 'seed $seed: crash at point $k');
            crashes++;
            if (twice) {
              // A second crash, inside the recovery itself, wherever it has steps.
              final again = OwnershipCoordinator(root.path);
              final inner = CrashAt(1 + g.r.nextInt(4));
              again.faultHook = inner.call;
              try {
                await again.recover();
              } on Crash {
                crashes++;
              }
            }
            final restarted = OwnershipCoordinator(root.path);
            await restarted.recover();
            await run(w, restarted, null);
            final reason = 'seed $seed: crash at point $k (${crash.points.last})${twice ? ' and in recovery' : ''}';
            final tree = await treeOf(root.path, ['recordings', 'ledger']);
            expect(tree.keys.toSet(), clean.keys.toSet(), reason: reason);
            for (final f in clean.keys) {
              expect(tree[f], clean[f], reason: '$reason: $f');
            }
            expect(restarted.journalFile.existsSync(), isFalse, reason: reason);
            expect(Directory('${root.path}/processing_temp').listSync(), isEmpty, reason: reason);
          } finally {
            root.deleteSync(recursive: true);
          }
        }
      }
    }
    expect(crashes, greaterThan(seeds * 4));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('files arriving in any order, some in parts, with publication between: one owner each', () async {
    for (var seed = 0; seed < seeds; seed++) {
      final g = TimelineGen(200 + seed);
      final bins = g.timeline();
      final ended = endedOf(bins);
      final policy = g.pick(genPolicies);
      final root = Directory.systemTemp.createTempSync('publish_arrival_');
      try {
        final w = World(root);
        final c = OwnershipCoordinator(root.path);
        final order = [...bins]..shuffle(g.r);
        final halves = {
          for (final b in order)
            if (g.chance(30) && b.frameOffsetsWritten.length > 2)
              b.key: b.frameOffsetsWritten[b.frameOffsetsWritten.length ~/ 2]
        };
        final steps = [
          for (final b in order) (b, halves[b.key]),
          for (final b in order)
            if (halves.containsKey(b.key)) (b, null),
        ];
        for (var i = 0; i < steps.length; i++) {
          final (b, upTo) = steps[i];
          await w.arrive(b, upTo: upTo);
          final here = w.bins.keys.toSet();
          final missing = [
            for (final x in bins)
              if (!here.contains(x.key)) x.key
          ];
          // Some missing files are given up on, so later audio closes past them.
          await w.drain(c,
              policy: policy,
              missing: missing,
              waived: {
                for (final k in missing)
                  if (g.chance(50)) k
              },
              endedSessions: ended,
              settings: g.settings(),
              pick: (_) => g.chance(60));
        }
        await w.drain(c, policy: policy, boundaries: g.forces(bins), endedSessions: ended, settings: g.settings());
        await _expectEveryFrameOwnedOnce(w, 'seed $seed');
      } finally {
        root.deleteSync(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
