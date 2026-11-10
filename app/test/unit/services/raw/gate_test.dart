import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/actions.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';

import 'plan_fixtures.dart';
import 'publish_fixtures.dart';

void main() {
  late Directory root;
  late World world;
  late OwnershipCoordinator c;
  late RawBinGate gate;
  late ArchiveActions actions;

  setUp(() {
    root = Directory.systemTemp.createTempSync('gate_');
    world = World(root);
    c = OwnershipCoordinator(root.path);
    gate = RawBinGate(c);
    actions = ArchiveActions(c);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A recording, then a long sleep and quiet: a recording and a discard once Forced.
  Future<Bin> conversationThenQuiet() async {
    final b = Bin(1789100000000)
      ..frames(300, p: speech)
      ..tap()
      ..frames(100, p: speech)
      ..resume(200000)
      ..frames(50, p: quiet);
    await world.arrive(b);
    return b;
  }

  Future<String?> blocked(RawFileKey k) => c.transact('t', () async => (const <JournalOp>[], await gate.blocked(k)));

  bool onPhone(RawFileKey k) => Directory(c.store.folderOf(k).path).existsSync();

  test('a file all published goes, leaving a receipt the planner reads as it read the card', () async {
    final b = Bin(1789100000000)
      ..frames(300, p: speech)
      ..tap()
      ..frames(100, p: speech);
    await world.arrive(b);
    await world.drain(c, boundaries: [b.force]);
    final withCard = await world.planFiles();
    expect(await gate.release(), {b.key});
    expect(onPhone(b.key), isFalse, reason: 'chunks, manifest and folder gone');
    final entry = (await ledgerOf(root.path))[b.key]!;
    expect(entry.receipt!.length, b.length);
    expect(entry.receipt!.lifecycle, SourceLifecycle.complete);
    expect(entry.summary!.events.length, withCard.single.events.length);
    final released = await world.planFiles();
    expect(released.single.released, isTrue);
    await expectNothingPublished(world, c, boundaries: [b.force]);
  });

  test('a discard keeps its audio until deleted or expired', () async {
    final b = await conversationThenQuiet();
    await world.drain(c, boundaries: [b.force]);
    expect(await blocked(b.key), contains('not owned for good'));
    expect(await gate.release(), isEmpty);
    final day = (await Archive.read(root.path)).discards.single;
    final end = day['endMs']! as int;
    expect(await actions.expireDiscards(nowMs: end + 47 * 3600 * 1000), 0);
    expect(await gate.release(), isEmpty);
    expect(await actions.expireDiscards(nowMs: end + 48 * 3600 * 1000), 1);
    expect((await Archive.read(root.path)).discards, isEmpty);
    expect(await gate.release(), {b.key});
  });

  test('still receiving, set aside, or read by a live job: kept', () async {
    // Two parts of 4 s each, so both are recordings (3 s of speech at least).
    final b = Bin(1789100000000)..frames(400, p: speech);
    await world.arrive(b, upTo: b.frameOffsetsWritten[200]);
    await actions.force([PlanBoundary(BoundaryKind.force, b.key, b.frameOffsetsWritten[200])]);
    await world.drain(c);
    expect(await blocked(b.key), 'still receiving');
    await world.arrive(b);
    await actions.force([b.force]);
    await world.drain(c);
    await actions.setAside(b.key);
    expect(await blocked(b.key), 'set aside');
    await actions.tryAgain(b.key);
    final job = await c.startJob(holds: {b.key});
    expect(await blocked(b.key), 'a job reads it');
    await c.finishJob(job);
    expect(await gate.release(), {b.key});
  });

  test('a frame or a tap nobody owns keeps the file', () async {
    final b = Bin(1789100000000)
      ..frames(300, p: speech)
      ..resume(200000)
      ..tap();
    await world.arrive(b);
    // Only what closed before the tap: the tap's own conversation is still open.
    await world.drain(c);
    expect(await blocked(b.key), contains('marker'));
    final unowned = Bin(1789200000000)..frames(10, p: speech);
    await world.arrive(unowned);
    expect(await blocked(unowned.key), contains('frame 0'));
  });

  test('a tombstoned file goes once terminal, whatever it holds', () async {
    final b = Bin(1789100000000)..frames(300, p: speech);
    await world.arrive(b, upTo: b.frameOffsetsWritten[100]);
    await actions.deleteRawFile(b.key, nowMs: 1);
    expect(await gate.release(), isEmpty, reason: 'still receiving: the rest is tombstoned too');
    await world.arrive(b);
    expect(await gate.release(), {b.key});
    expect((await ledgerOf(root.path))[b.key]!.tombstone!.reason, 'deleteFile');
    await expectNothingPublished(world, c, boundaries: [b.force]);
  });

  test('a crash between the receipt and the delete: recovery finishes the release', () async {
    final b = Bin(1789100000000)..frames(300, p: speech);
    await world.arrive(b);
    await world.drain(c, boundaries: [b.force]);
    final crash = CrashAt(1 << 30);
    c.faultHook = (p) {
      if (p == 'op.1') crash.crashed = true;
      crash(p);
    };
    await expectLater(gate.release(), throwsA(isA<Crash>()));
    expect((await ledgerOf(root.path))[b.key]!.receipt, isNotNull);
    expect(onPhone(b.key), isTrue);
    await OwnershipCoordinator(root.path).recover();
    expect(onPhone(b.key), isFalse);
  });

  test('a released file whose copy comes back is deleted again; its receipt stands', () async {
    final b = Bin(1789100000000)..frames(300, p: speech);
    await world.arrive(b);
    await world.drain(c, boundaries: [b.force]);
    expect(await gate.release(), {b.key});
    final receipt = (await ledgerOf(root.path))[b.key]!.receipt!.toJson();
    await world.arrive(b);
    expect(onPhone(b.key), isTrue);
    await expectNothingPublished(world, c, boundaries: [b.force], reason: 'planned from its receipt');
    expect(await gate.release(), {b.key});
    expect(onPhone(b.key), isFalse);
    expect((await ledgerOf(root.path))[b.key]!.receipt!.toJson(), receipt);
  });
}
