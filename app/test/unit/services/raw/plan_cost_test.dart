// What planning costs (RECORDINGS_PIPELINE_REDESIGN.md §3, "Cost"): a day of continuous
// audio is 4.32 million frames in 144 ten-minute files. Measured on the host; a phone is
// several times slower, so the bounds here only catch a planner that stopped being linear
// or started allocating per frame.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';

import 'plan_fixtures.dart';

const _framesPerFile = 30000; // ten minutes
const _filesPerDay = 144;

/// A ten-minute file as its card holds it: speech in runs of a few seconds to a few
/// minutes, quiet between, now and then a tap.
FileCard _card(RawFileKey key, Random r, {bool taps = true, bool stopFirst = false}) {
  final offsets = Uint32List(_framesPerFile);
  final lengths = Uint16List(_framesPerFile)..fillRange(0, _framesPerFile, 80);
  for (var i = 0; i < _framesPerFile; i++) {
    offsets[i] = 36 + i * 84;
  }
  final events = <CardEvent>[
    CardEvent(
        kind: CardEventKind.header,
        offset: 0,
        frameIndex: 0,
        utcMs: key.timerStart * 1000,
        uptimeMs: 1000000 + key.timerStart,
        sessionId: key.sessionId),
    if (stopFirst)
      CardEvent(
          kind: CardEventKind.stop,
          offset: 16,
          frameIndex: 0,
          utcMs: key.timerStart * 1000,
          uptimeMs: 0,
          sessionId: key.sessionId),
  ];
  final speech = Float32List(_framesPerFile);
  var i = 0;
  var talking = r.nextBool();
  while (i < _framesPerFile) {
    final run = talking ? 100 + r.nextInt(9000) : 100 + r.nextInt(8000);
    for (var j = i; j < min(i + run, _framesPerFile); j++) {
      speech[j] = talking ? 0.6 + r.nextDouble() * 0.4 : r.nextDouble() * 0.4;
    }
    if (taps && talking && r.nextInt(20) == 0 && i > 0) {
      events.add(CardEvent(
          kind: CardEventKind.tap,
          offset: offsets[i] - 20,
          frameIndex: i,
          utcMs: key.timerStart * 1000 + i * frameMs,
          uptimeMs: 0,
          sessionId: key.sessionId));
    }
    i += run;
    talking = !talking;
  }
  final records = ParsedRecords(
    frameOffsets: offsets,
    frameLengths: lengths,
    events: events,
    parsedEnd: 36 + _framesPerFile * 84,
    length: 36 + _framesPerFile * 84,
    stop: ParseStop.none,
  );
  return FileCard(
    key: key,
    indexerVersion: cardIndexerVersion,
    chunks: [(0, records.length)],
    records: records,
    decoderId: 'opus',
    vadModelId: 'silero',
    audio: FrameAudio(decoded: Uint8List(_framesPerFile)..fillRange(0, _framesPerFile, 1), speech: speech),
  );
}

void main() {
  test('a day of continuous audio: loading its cards and planning it', () {
    final r = Random(1);
    const start = 1789000000;
    final encoded = [
      for (var f = 0; f < _filesPerDay; f++) _card(RawFileKey(start + f * 600, 7), r).encode(),
    ];

    final load = Stopwatch()..start();
    final files = [
      for (final bytes in encoded)
        () {
          final card = FileCard.decode(bytes);
          return PlanFile(
              key: card.key,
              records: card.records,
              audio: card.audio,
              hasVad: true,
              lifecycle: SourceLifecycle.complete);
        }()
    ];
    load.stop();

    final walk = Stopwatch()..start();
    final p = planOf(files, boundaries: [PlanBoundary(BoundaryKind.force, files.last.key, 1 << 40)]);
    walk.stop();

    final frames = p.items.expand((i) => i.spans).fold<int>(0, (n, s) => n + s.length);
    expect(frames, _filesPerDay * _framesPerFile, reason: 'every frame planned');

    // The same day once it is all published: every frame a wall.
    final owned = ownershipOf(p.items);
    final replan = Stopwatch()..start();
    final again = planOf(files, owned: owned, boundaries: [PlanBoundary(BoundaryKind.force, files.last.key, 1 << 40)]);
    replan.stop();
    expect(again.items, isEmpty);

    // ignore: avoid_print
    print('a day: ${encoded.fold<int>(0, (n, b) => n + b.length) ~/ 1000000} MB of cards loaded in '
        '${load.elapsedMilliseconds} ms, planned in ${walk.elapsedMilliseconds} ms into ${p.items.length} items, '
        'replanned published in ${replan.elapsedMilliseconds} ms');
    expect(walk.elapsedMilliseconds, lessThan(5000));
    expect(replan.elapsedMilliseconds, lessThan(5000));
  });

  test('a day latched after a stop', () {
    final r = Random(2);
    const start = 1789000000;
    final files = [
      for (var f = 0; f < _filesPerDay; f++)
        () {
          final card = _card(RawFileKey(start + f * 600, 7), r, taps: false, stopFirst: f == 0);
          return PlanFile(
              key: card.key,
              records: card.records,
              audio: card.audio,
              hasVad: true,
              lifecycle: SourceLifecycle.complete);
        }()
    ];
    final walk = Stopwatch()..start();
    final p = planOf(files, boundaries: [PlanBoundary(BoundaryKind.force, files.last.key, 1 << 40)]);
    walk.stop();
    final d = p.items.whereType<PlannedDiscard>().single;
    expect(d.kind, DiscardKind.afterStop);
    expect(d.audioMs, _filesPerDay * _framesPerFile * frameMs);
    // ignore: avoid_print
    print('a latched day planned in ${walk.elapsedMilliseconds} ms');
    expect(walk.elapsedMilliseconds, lessThan(5000));
  });

  test('holes waived by later Forces alone cost no more than linearly', () {
    // Enough that a scan of every boundary per hole (1.8 billion comparisons) cannot pass.
    const n = 60000;
    final missing = [for (var i = 0; i < n; i++) RawFileKey(1789000000 + i * 600, 7)];
    final walk = Stopwatch()..start();
    final p = planOf(const [],
        missing: missing,
        boundaries: [for (final k in missing) PlanBoundary(BoundaryKind.force, RawFileKey(k.timerStart + 1, 7), 0)]);
    walk.stop();
    expect(p.stoppedAt, isEmpty, reason: 'each hole is waived by the Force at the file after it');
    // ignore: avoid_print
    print('$n holes waived by Forces planned in ${walk.elapsedMilliseconds} ms');
    expect(walk.elapsedMilliseconds, lessThan(2000));
  });

  test('many given-up files and boundaries cost no more than linearly', () {
    const n = 20000;
    final missing = [for (var i = 0; i < n; i++) RawFileKey(1789000000 + i * 600, 7)];
    final walk = Stopwatch()..start();
    final p = planOf(const [],
        missing: missing,
        waived: missing.toSet(),
        boundaries: [for (final k in missing) PlanBoundary(BoundaryKind.force, k, 0)]);
    walk.stop();
    expect(p.stoppedAt, isEmpty);
    // ignore: avoid_print
    print('$n given-up files and boundaries planned in ${walk.elapsedMilliseconds} ms');
    expect(walk.elapsedMilliseconds, lessThan(2000));
  });
}
