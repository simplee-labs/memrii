import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/services/raw/archive_files.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';

import 'plan_fixtures.dart';
import 'publish_fixtures.dart';

void main() {
  late Directory root;
  late World world;
  late OwnershipCoordinator c;

  setUp(() {
    root = Directory.systemTemp.createTempSync('coordinator_');
    world = World(root);
    c = OwnershipCoordinator(root.path);
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// Speech, a tap, speech, a long sleep that closes it, quiet, and Force.
  Future<Bin> oneConversation() async {
    final b = Bin(1789100000000)
      ..frames(200, p: speech)
      ..tap()
      ..frames(200, p: speech)
      ..resume(200000)
      ..frames(100, p: quiet);
    await world.arrive(b);
    return b;
  }

  Future<Plan> planNow({List<PlanBoundary> boundaries = const []}) async {
    final files = await world.planFiles();
    final snap = await c.snapshot(files.map((f) => f.key));
    return plan(PlanInput(
      files: files,
      boundaries: boundaries,
      owned: snap.ownershipFor(files),
      policies: const PolicyHistory(autoPolicy),
      caps: CapHistory.constant(120),
    ));
  }

  PublishJob job({Future<int?> Function()? free, FakeEncoder? encoder}) => PublishJob(
        coordinator: c,
        newDecoder: FakeOpus.new,
        encoder: encoder,
        freeBytes: free ?? () async => null,
      );

  Future<PublishReport> publish(Plan p, int generation,
          {PublishSettings settings = const PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF', opusSidecar: true),
          Future<int?> Function()? free,
          FakeEncoder? encoder}) async =>
      job(free: free, encoder: encoder).publish(
        items: p.items,
        generation: generation,
        files: {for (final f in await world.planFiles()) f.key: f},
        cards: world.cards,
        settings: settings,
      );

  test('a recording, its marker and the quiet after it: published, owned, staging gone', () async {
    final b = await oneConversation();
    final p = await world.drain(c, boundaries: [b.force]);
    expect(p.items, isEmpty);
    final archive = await Archive.read(root.path);
    final date = localDateOf(1789100000000);
    final rel = 'recordings/$date/recording_1789100000000.wav';
    expect(archive.heard.keys, [rel]);
    expect(archive.heard[rel]!.length, 400);
    final conv = Conversation.fromFile(File('${root.path}/$rel'));
    expect(conv.duration, const Duration(seconds: 8));
    expect(conv.uploadKey, 'AABBCC_recording_1789100000000.wav');
    expect(conv.relativeBins, [b.key.rel]);
    expect(archive.edls.single['segmentFilename'], 'recording_1789100000000.wav');
    expect(archive.edls.single['markerOffsetMs'], 4000);
    expect(archive.discards.single['reason'], 'flush_noise');
    expect(archive.sidecars[rel]!.length, 400);
    final entry = (await ledgerOf(root.path))[b.key]!;
    final records = world.cards[b.key]!.records;
    expect(entry.frames, [
      OwnedRange(records.frameOffsets[0], records.frameOffsets[399] + 12,
          Owner(OwnerKind.recording, '$date/recording_1789100000000')),
      OwnedRange(records.frameOffsets[400], records.frameOffsets[499] + 12,
          Owner(OwnerKind.discard, archive.discards.single['id']! as String)),
    ]);
    expect(entry.events.values.single.kind, OwnerKind.recording);
    expect(entry.summary!.frameCount, 500);
    expect(Directory('${root.path}/processing_temp').listSync(), isEmpty);
    expect(c.journalFile.existsSync(), isFalse);
  });

  test('M4A: published as .m4a, keyed and marked as .m4a', () async {
    final b = await oneConversation();
    final enc = FakeEncoder();
    await world.drain(c,
        boundaries: [b.force], encoder: enc, settings: const PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF', m4a: true));
    final dir = Directory('${root.path}/recordings/${localDateOf(1789100000000)}');
    final names = dir.listSync().map((e) => e.uri.pathSegments.last).toSet();
    expect(names, containsAll(['recording_1789100000000.m4a', 'recording_1789100000000.meta']));
    expect(names.any((n) => n.endsWith('.wav')), isFalse);
    expect(Conversation.fromFile(File('${dir.path}/recording_1789100000000.m4a')).uploadKey,
        'AABBCC_recording_1789100000000.m4a');
    expect((await Archive.read(root.path)).edls.single['segmentFilename'], 'recording_1789100000000.m4a');
  });

  group('dropped, with nothing written', () {
    Future<void> expectNothing() async {
      expect(Directory('${root.path}/recordings').existsSync(), isFalse);
      expect((await ledgerOf(root.path)).values.every((e) => e.frames.isEmpty), isTrue);
      expect(Directory('${root.path}/processing_temp').listSync(), isEmpty);
    }

    test('R3: planned under a generation Reprocess all has since advanced', () async {
      final b = await oneConversation();
      final p = await planNow(boundaries: [b.force]);
      final snap = await c.snapshot([b.key]);
      await c.advanceGeneration();
      final report = await publish(p, snap.generation);
      expect(report.stop, PublishStop.stale);
      expect(report.published, 0);
      await expectNothing();
      expect((await c.snapshot([b.key])).generation, 1);
    });

    test('already owned: two jobs from one plan, the second dropped', () async {
      final b = await oneConversation();
      final p = await planNow(boundaries: [b.force]);
      expect((await publish(p, 0)).stop, PublishStop.done);
      final before = await treeOf(root.path, ['recordings', 'ledger']);
      expect((await publish(p, 0)).stop, PublishStop.stale);
      expect(await treeOf(root.path, ['recordings', 'ledger']), before);
    });

    test('frames owned already, with no marker to give it away: dropped before anything moves', () async {
      final b = Bin(1789100000000)
        ..frames(300, p: speech)
        ..resume(200000)
        ..frames(10, p: quiet);
      await world.arrive(b);
      final p = await planNow(boundaries: [b.force]);
      expect(p.items.every((i) => i.events.isEmpty), isTrue);
      expect((await publish(p, 0)).stop, PublishStop.done);
      final before = await treeOf(root.path, ['recordings', 'ledger']);
      expect((await publish(p, 0)).stop, PublishStop.stale);
      expect(await treeOf(root.path, ['recordings', 'ledger']), before);
      expect(c.journalFile.existsSync(), isFalse);
    });

    test('a marker owned already, with no frames to give it away: dropped before its EDL is written', () async {
      final b = Bin(1789100000000)..tap();
      await world.arrive(b);
      final p = await planNow(boundaries: [b.force]);
      expect(p.items.single, isA<PlannedOrphans>());
      expect((await publish(p, 0)).stop, PublishStop.done);
      final before = await treeOf(root.path, ['recordings', 'ledger']);
      expect((await publish(p, 0)).stop, PublishStop.stale);
      expect(await treeOf(root.path, ['recordings', 'ledger']), before);
    });

    test('a tombstoned file with no marker in the item: dropped', () async {
      final b = Bin(1789100000000)
        ..frames(300, p: speech)
        ..resume(200000)
        ..frames(10, p: quiet);
      await world.arrive(b);
      final p = await planNow(boundaries: [b.force]);
      final day = await c.ledger.loadDay(ledgerDayOf(b.key));
      day.entryFor(b.key).tombstone = const Tombstone(1, 'deleteDay');
      await c.ledger.saveDay(day);
      expect((await publish(p, 0)).stop, PublishStop.stale);
      expect(Directory('${root.path}/recordings').existsSync(), isFalse);
    });

    test('a file deleted at its source (tombstoned): never published, and owned whole for the planner', () async {
      final b = await oneConversation();
      final p = await planNow(boundaries: [b.force]);
      final day = await c.ledger.loadDay(ledgerDayOf(b.key));
      day.entryFor(b.key).tombstone = const Tombstone(1, 'deleteDay');
      await c.ledger.saveDay(day);
      expect((await publish(p, 0)).stop, PublishStop.stale);
      expect(Directory('${root.path}/recordings').existsSync(), isFalse);
      expect((await planNow(boundaries: [b.force])).items, isEmpty);
    });

    test('ranges past the sealed bytes, and a job that is not live', () async {
      final b = await oneConversation();
      final p = await planNow(boundaries: [b.force]);
      final discard = p.items.whereType<PlannedDiscard>().single;
      final handle = await c.startJob();
      CommitRequest req(Map<RawFileKey, List<(int, int)>> bytes) => CommitRequest(
            job: handle,
            generation: 0,
            items: [StagedItem(discard, bytes)],
            summaries: {b.key: world.cards[b.key]!.summary},
            deviceId: '',
          );
      expect(
          (await c.commit(req({
            b.key: [(36, b.length + 4)]
          })))
              .rejected,
          contains('is not in its'));
      expect(
          (await c.commit(req({
            b.key: [(36, 48), (40, 60)]
          })))
              .rejected,
          contains('claimed twice'));
      await c.finishJob(handle);
      expect(
          (await c.commit(req({
            b.key: [(36, 48)]
          })))
              .rejected,
          'the job is not live');
      await expectNothing();
    });
  });

  test('a summary from a shorter card never replaces a longer one', () async {
    const key = RawFileKey(1789100000, 7);
    EventSummary summary(int length) =>
        EventSummary(key: key, length: length, frameCount: 1, firstFrameOffset: 36, events: const [], hasVad: true);
    Future<void> apply(Claim claim, int length) async {
      c.journalFile.writeAsStringSync(jsonEncode({
        'v': 1,
        'id': 't',
        'ops': [
          ClaimOp(ledgerDayOf(key), [claim], [summary(length)]).toJson()
        ],
      }));
      await c.recover();
    }

    await apply(const Claim(key, Owner(OwnerKind.discard, 'a'), [(500, 600)], []), 1000);
    await apply(const Claim(key, Owner(OwnerKind.discard, 'b'), [(36, 100)], []), 400);
    expect((await ledgerOf(root.path))[key]!.summary!.length, 1000);
  });

  group('the job', () {
    /// Two conversations a long sleep apart, quiet after them, and Force.
    Future<Bin> twoConversations() async {
      final b = Bin(1789100000000)
        ..frames(300, p: speech)
        ..resume(200000)
        ..frames(300, p: speech)
        ..resume(200000)
        ..frames(10, p: quiet);
      await world.arrive(b);
      return b;
    }

    Future<PublishReport> run(OwnershipCoordinator coordinator, Plan p,
            {bool Function()? cancelled,
            Future<int?> Function()? free,
            FakeOpus Function()? decoder,
            void Function(String)? fault}) async =>
        PublishJob(
          coordinator: coordinator,
          newDecoder: decoder ?? FakeOpus.new,
          freeBytes: free ?? () async => null,
          isCancelled: cancelled,
          faultHook: fault,
        ).publish(
          items: p.items,
          generation: 0,
          files: {for (final f in await world.planFiles()) f.key: f},
          cards: world.cards,
          settings: const PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF'),
        );

    test('Stop while the last recording is prepared: its rendered batch is not committed', () async {
      final b = await twoConversations();
      final p = await planNow(boundaries: [b.force]);
      var stopped = false;
      var asked = 0;
      // Stop pressed while the free space is read for the second recording, which is too
      // short to reach a check inside its render.
      final report = await run(c, p,
          cancelled: () => stopped,
          free: () async {
            if (++asked == 2) stopped = true;
            return null;
          });
      expect(report.stop, PublishStop.cancelled);
      expect(report.published, 0);
      expect(Directory('${root.path}/recordings').existsSync(), isFalse);
      expect(Directory('${root.path}/processing_temp').listSync(), isEmpty);
    });

    test('Stop while the commit waits for the queue: the coordinator drops it', () async {
      final b = await twoConversations();
      final p = await planNow(boundaries: [b.force]);
      var rendered = 0;
      var stopped = false;
      Future<T> queue<T>(Future<T> Function() body) {
        // Stop pressed while a user action held the queue, after the job last looked.
        if (rendered == 2) stopped = true;
        return body();
      }

      final report = await run(OwnershipCoordinator(root.path, queue: queue), p,
          cancelled: () => stopped,
          fault: (point) {
            if (point == 'rendered') rendered++;
          });
      expect(report.stop, PublishStop.cancelled);
      expect(report.published, 0);
      expect(Directory('${root.path}/recordings').existsSync(), isFalse);
    });

    test('a decoder that breaks in the second recording: the first is still published', () async {
      final b = await twoConversations();
      final p = await planNow(boundaries: [b.force]);
      final recordings = p.items.whereType<PlannedRecording>().toList();
      expect(recordings.length, 2);
      final report = await run(c, p, decoder: () => FakeOpus(failAfter: 400));
      expect(report.stop, PublishStop.failed);
      expect(report.failedItem, recordings[1]);
      expect(report.published, 1);
      final archive = await Archive.read(root.path);
      expect(archive.heard.values.single.map((h) => h.$1.$2), List.generate(300, (i) => i));
      expect(Directory('${root.path}/processing_temp').listSync(), isEmpty);
    });
  });

  test('storage: nothing rendered without room for the WAV and the M4A beside it', () async {
    final b = await oneConversation();
    final p = await planNow(boundaries: [b.force]);
    final report = await publish(p, 0, free: () async => 200 * 1024 * 1024 + 1000);
    expect(report.stop, PublishStop.storageFull);
    expect(Directory('${root.path}/recordings').existsSync(), isFalse);
    expect(Directory('${root.path}/processing_temp').listSync(), isEmpty);
  });

  group('recovery', () {
    test('a journal left by a crash is completed, and completing it again changes nothing', () async {
      final b = await oneConversation();
      final crash = CrashAt(1 << 30);
      c.faultHook = (point) {
        if (point == 'op.2') crash.crashed = true;
        crash(point);
      };
      await expectLater(world.drain(c, boundaries: [b.force]), throwsA(isA<Crash>()));
      expect(c.journalFile.existsSync(), isTrue);
      final restarted = OwnershipCoordinator(root.path);
      await restarted.recover();
      expect(restarted.journalFile.existsSync(), isFalse);
      final after = await treeOf(root.path, ['recordings', 'ledger']);
      expect(after.keys.where((k) => k.endsWith('.wav')).length, 1);
      // Applying the same journal again is a no-op.
      final again = File('${root.path}/journal.copy');
      expect(again.existsSync(), isFalse);
      await restarted.recover();
      expect(await treeOf(root.path, ['recordings', 'ledger']), after);
      expect(Directory('${root.path}/processing_temp').listSync(), isEmpty);
    });

    test('every op replayed twice gives the same archive', () async {
      final b = await oneConversation();
      Map<String, Object?>? journal;
      c.faultHook = (point) {
        if (point == 'journal.written') journal = jsonDecode(c.journalFile.readAsStringSync()) as Map<String, Object?>;
      };
      await world.drain(c, boundaries: [b.force]);
      final done = await treeOf(root.path, ['recordings', 'ledger']);
      // The last transaction's journal, put back: every move is found done, every write
      // and claim is the same again.
      c.journalFile.writeAsStringSync(jsonEncode(journal));
      await OwnershipCoordinator(root.path).recover();
      expect(await treeOf(root.path, ['recordings', 'ledger']), done);
    });

    test('a staged file gone with its destination never written stops the journal', () async {
      c.journalFile.writeAsStringSync(jsonEncode({
        'v': 1,
        'id': 't',
        'ops': [const MoveOp('processing_temp/job-1/0/a.wav', 'recordings/2026-01-01/recording_1.wav').toJson()],
      }));
      await expectLater(c.recover(), throwsA(isA<JournalStuck>()));
      expect(c.journalFile.existsSync(), isTrue);
    });

    test('a destination already taken stops the journal: nothing overwritten, the staging kept', () async {
      final stage = File('${root.path}/processing_temp/job-1/0/a.wav')..createSync(recursive: true);
      final taken = File('${root.path}/recordings/2026-01-01/recording_1.wav')
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      c.journalFile.writeAsStringSync(jsonEncode({
        'v': 1,
        'id': 't',
        'ops': [const MoveOp('processing_temp/job-1/0/a.wav', 'recordings/2026-01-01/recording_1.wav').toJson()],
      }));
      await expectLater(c.recover(), throwsA(isA<JournalStuck>()));
      expect(taken.readAsStringSync(), 'mine');
      expect(stage.existsSync(), isTrue);
      expect(c.journalFile.existsSync(), isTrue);
    });

    test('abandoned staging goes; a live job\'s stays', () async {
      final live = await c.startJob();
      File('${live.staging.path}/0/audio.wav').createSync(recursive: true);
      final dead = Directory('${root.path}/processing_temp/job-0-0')..createSync(recursive: true);
      final old = Directory('${root.path}/processing_temp/2026-01-01')..createSync(recursive: true);
      await c.recover();
      expect(live.staging.existsSync(), isTrue);
      expect(dead.existsSync(), isFalse);
      expect(old.existsSync(), isTrue, reason: 'not a job\'s: the update (§13) handles the old pipeline\'s');
    });

    test('an apply that fails: the job\'s end completes the journal before its staging goes', () async {
      final b = await oneConversation();
      var fail = true;
      c.faultHook = (point) {
        if (fail && point == 'op.1') {
          fail = false;
          throw const FileSystemException('transient');
        }
      };
      await expectLater(world.drain(c, boundaries: [b.force]), throwsA(isA<FileSystemException>()));
      expect(c.journalFile.existsSync(), isFalse);
      final archive = await Archive.read(root.path);
      expect(archive.heard.values.single.length, 400);
      expect(Directory('${root.path}/processing_temp').listSync(), isEmpty);
    });
  });
}
