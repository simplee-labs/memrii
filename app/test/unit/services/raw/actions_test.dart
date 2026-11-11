import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/actions.dart';
import 'package:omi/services/raw/archive_files.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/raw/render.dart';

import 'plan_fixtures.dart';
import 'publish_fixtures.dart';

void main() {
  late Directory root;
  late World world;
  late OwnershipCoordinator c;
  late ArchiveActions actions;

  setUp(() {
    root = Directory.systemTemp.createTempSync('actions_');
    world = World(root);
    c = OwnershipCoordinator(root.path);
    actions = ArchiveActions(c);
  });
  tearDown(() => root.deleteSync(recursive: true));

  const settings = PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF', opusSidecar: true);

  /// Speech with a tap, a long sleep, then quiet: a recording and a discard once Forced.
  Future<Bin> conversationThenQuiet({int start = 1789100000000, int session = 7}) async {
    final b = Bin(start, session: session)
      ..frames(300, p: speech)
      ..tap()
      ..frames(100, p: speech)
      ..resume(200000)
      ..frames(50, p: quiet);
    await world.arrive(b);
    return b;
  }

  Future<RecoverResult> recover(List<String> ids, {Future<int?> Function()? free}) =>
      actions.recoverDiscards(ids, cards: world.cards, newDecoder: FakeOpus.new, settings: settings, freeBytes: free);

  Owner ownerAt(LedgerEntry e, int offset) => e.frames.firstWhere((r) => r.start <= offset && offset < r.end).owner;

  group('discards', () {
    test('deleted: the record goes, its audio becomes a derived deletion', () async {
      final b = await conversationThenQuiet();
      await world.drain(c, boundaries: [b.force]);
      final id = (await Archive.read(root.path)).discards.single['id']! as String;
      expect(await actions.deleteDiscards([id]), 1);
      expect((await Archive.read(root.path)).discards, isEmpty);
      final entry = (await ledgerOf(root.path))[b.key]!;
      expect(ownerAt(entry, b.frameOffsetsWritten[420]), deletedDiscard);
      expect(ownerAt(entry, b.frameOffsetsWritten[0]).kind, OwnerKind.recording);
      expect(await actions.deleteDiscards([id]), 0, reason: 'already gone');
    });

    test('recovered: its frames, in order and nothing else, as one recording in its place', () async {
      final b = await conversationThenQuiet();
      await world.drain(c, boundaries: [b.force]);
      final before = await Archive.read(root.path);
      final d = before.discards.single;
      final result = await recover([d['id']! as String]);
      expect(result.stop, RecoverStop.recovered);
      final after = await Archive.read(root.path);
      expect(after.discards, isEmpty);
      final heard = after.heard[result.published]!;
      expect([for (final h in heard) h.$1], [for (var i = 400; i < 450; i++) (frameTag(b.key), i)]);
      expect([for (final h in heard) h.$2], List.filled(50, 0), reason: 'no padding');
      expect(after.sidecars[result.published]!.length, 50);
      final name = result.published!.split('/').last;
      expect(int.parse(name.split('.').first.split('_').last), greaterThanOrEqualTo(d['startMs']! as int));
      final entry = (await ledgerOf(root.path))[b.key]!;
      expect(ownerAt(entry, b.frameOffsetsWritten[420]),
          Owner(OwnerKind.recording, '${localDateOf(d['startMs']! as int)}/${name.split('.').first}'));
      expect((await recover([d['id']! as String])).stop, RecoverStop.stale, reason: 'recovered already');
      expect(await RawBinGate(c).release(), {b.key}, reason: 'everything owned for good now');
    });

    test('recovery is stale after Reprocess all reuses the same discard id', () async {
      final b = Bin(1789100000000)..frames(50, p: quiet);
      await world.arrive(b);
      await world.drain(c, boundaries: [b.force]);
      final id = (await Archive.read(root.path)).discards.single['id']! as String;
      final result = await recover([id], free: () async {
        b.frames(250, p: quiet);
        await world.arrive(b);
        await actions.reprocessAll();
        await world.drain(c, boundaries: [b.force]);
        expect((await Archive.read(root.path)).discards.single['id'], id);
        return null;
      });
      expect(result.stop, RecoverStop.stale);
      final after = await Archive.read(root.path);
      expect(after.heard, isEmpty);
      expect(after.discards.single['id'], id);
      expect(ownerAt((await ledgerOf(root.path))[b.key]!, b.frameOffsetsWritten.last), Owner(OwnerKind.discard, id));
      expect(await RawBinGate(c).release(), isEmpty, reason: 'unrecovered audio must remain');
    });

    test('recovery transfers only the audio it rendered even if its owner gains more', () async {
      final b = Bin(1789100000000)..frames(50, p: quiet);
      await world.arrive(b);
      await world.drain(c, boundaries: [b.force]);
      final id = (await Archive.read(root.path)).discards.single['id']! as String;
      final owner = Owner(OwnerKind.discard, id);
      final result = await recover([id], free: () async {
        final start = b.length;
        b.frames(25, p: quiet);
        await world.arrive(b);
        // Exercise the commit contract independently of generation rejection.
        await c.transact(
            'extend-owner',
            () async => (
                  <JournalOp>[
                    ClaimOp(ledgerDayOf(b.key), [
                      Claim(b.key, owner, [(start, b.length)], const [])
                    ], const [])
                  ],
                  null
                ));
        return null;
      });
      expect(result.stop, RecoverStop.recovered);
      final heard = (await Archive.read(root.path)).heard[result.published]!;
      expect([for (final h in heard) h.$1], [for (var i = 0; i < 50; i++) (frameTag(b.key), i)]);
      final entry = (await ledgerOf(root.path))[b.key]!;
      expect(ownerAt(entry, b.frameOffsetsWritten[49]).kind, OwnerKind.recording);
      expect(ownerAt(entry, b.frameOffsetsWritten[50]), owner);
      expect(await RawBinGate(c).release(), isEmpty);
    });

    test('several discards recover in start order across files without padding', () async {
      final bins = [
        for (var i = 0; i < 3; i++) Bin(1789100000000 + i * 3600000, session: 7 + i)..frames(10 + i, p: quiet)
      ];
      for (final b in bins.reversed) {
        await world.arrive(b);
        await world.drain(c, boundaries: [b.force]);
      }
      final ds = (await Archive.read(root.path)).discards
        ..sort((a, b) => (b['startMs']! as int).compareTo(a['startMs']! as int));
      expect(ds.length, 3);
      final result = await recover([for (final d in ds) d['id']! as String]);
      expect(result.stop, RecoverStop.recovered);
      final after = await Archive.read(root.path);
      expect(after.discards, isEmpty);
      final heard = after.heard[result.published]!;
      expect([
        for (final h in heard) h.$1
      ], [
        for (final b in bins)
          for (var i = 0; i < b.frameCount; i++) (frameTag(b.key), i)
      ]);
      expect([for (final h in heard) h.$2], List.filled(33, 0));
      expect(after.sidecars[result.published]!.length, 33);
    });

    test('deleted while its recovery was rendering: the recovery is dropped', () async {
      final b = await conversationThenQuiet();
      await world.drain(c, boundaries: [b.force]);
      final id = (await Archive.read(root.path)).discards.single['id']! as String;
      final result = await recover([id], free: () async {
        await actions.deleteDiscards([id]);
        return null;
      });
      expect(result.stop, RecoverStop.stale);
      expect((await Archive.read(root.path)).heard.length, 1, reason: 'only the original recording');
      expect(ownerAt((await ledgerOf(root.path))[b.key]!, b.frameOffsetsWritten[420]), deletedDiscard);
      expect(Directory('${root.path}/processing_temp').listSync(), isEmpty);
    });

    test('its file deleted at the source and released: nothing to recover, the row goes', () async {
      final b = await conversationThenQuiet();
      await world.drain(c, boundaries: [b.force]);
      final id = (await Archive.read(root.path)).discards.single['id']! as String;
      await actions.deleteRawFile(b.key, nowMs: 1);
      expect(await RawBinGate(c).release(), {b.key});
      expect((await recover([id])).stop, RecoverStop.nothingToRecover);
      expect((await Archive.read(root.path)).discards, isEmpty);
    });

    test('a recovery from a job that is no longer live is dropped', () async {
      final b = await conversationThenQuiet();
      await world.drain(c, boundaries: [b.force]);
      final d = (await Archive.read(root.path)).discards.single;
      final job = await c.startJob();
      await c.finishJob(job);
      final result = await c.commitRecovery(RecoveryRequest(
        job: job,
        generation: 0,
        discards: {d['id']! as String: localDateOf(d['startMs']! as int)},
        recording: PlannedRecording(
          sessionId: 7,
          closeType: CloseType.recovered,
          closedAt: PlanPosition(b.key, -1),
          pieces: [FramesPiece(FrameSpan(b.key, 400, 450))],
          startMs: d['startMs']! as int,
          startUptimeSeconds: null,
          derivedTime: false,
          markers: const [],
          durationMs: 1000,
          frameCount: 50,
          silero: false,
          manual: null,
        ),
        rendered: RenderedRecording(
            audio: File('${job.staging.path}/audio.wav'),
            extension: 'wav',
            totalSamples: 16000,
            peaks: Uint16List(200),
            sidecar: null),
        bytes: {
          b.key: [(b.frameOffsetsWritten[400], b.frameOffsetsWritten[449] + 12)]
        },
        deviceId: '',
      ));
      expect(result.rejected, 'the job is not live');
      expect((await Archive.read(root.path)).discards.length, 1);
    });

    test('a muted interval with nothing recorded: nothing to recover, so it is deleted', () async {
      final b = Bin(1789100000000)
        ..frames(200, p: speech)
        ..muteOn()
        ..resume(5000)
        ..muteOff()
        ..frames(200, p: speech);
      await world.arrive(b);
      await world.drain(c, boundaries: [b.force]);
      final muted = (await Archive.read(root.path)).discards.where((d) => d['reason'] == 'muted').single;
      expect((await recover([muted['id']! as String])).stop, RecoverStop.nothingToRecover);
      expect((await Archive.read(root.path)).discards.where((d) => d['reason'] == 'muted'), isEmpty);
    });
  });

  test('Delete Day: the day\'s archive goes, its raw files are tombstoned and released', () async {
    final a = await conversationThenQuiet();
    // Not processed yet, dated the same day: tombstoned too.
    final later = Bin(1789100000000 + 3600 * 1000, session: 8)..frames(200, p: speech);
    await world.arrive(later);
    final otherDay = await conversationThenQuiet(start: 1789100000000 + 3 * 86400 * 1000, session: 9);
    await world.drain(c, boundaries: [a.force, otherDay.force]);
    // A marker of this day filed beside another day's recording belongs to that recording,
    // which runs past midnight: it stays with it.
    final day = localDateOf(1789100000000);
    final elsewhere = localDateOf(otherDay.key.timerStart * 1000);
    File('${root.path}/recordings/$elsewhere/marker_${1789100000000 + 5}.edl')
        .writeAsStringSync('{"markerTimestampMs": ${1789100000000 + 5}, "segmentFilename": ""}');
    final deleted = await actions.deleteDay(day, nowMs: 42);
    expect(deleted, ['recordings/$day/recording_1789100000000.wav']);
    expect(Directory('${root.path}/recordings/$day').existsSync(), isFalse);
    expect(File('${root.path}/recordings/$elsewhere/marker_${1789100000000 + 5}.edl').existsSync(), isTrue);
    final ledger = await ledgerOf(root.path);
    expect(ledger[a.key]!.tombstone!.reason, 'deleteDay');
    expect(ledger[later.key]!.tombstone, isNotNull);
    expect(ledger[otherDay.key]!.tombstone, isNull);
    await expectNothingPublished(world, c, boundaries: [a.force, later.force, otherDay.force]);
    expect(await RawBinGate(c).release(), {a.key, later.key}, reason: 'the other day still has its discard');
  });

  test('Delete Day reads passthrough metadata whose raw file is dated the previous day', () async {
    final start = DateTime(2026, 9, 11, 0, 0, 1).millisecondsSinceEpoch;
    final b = Bin(start, keySeconds: (start - 2000) ~/ 1000)..frames(200, p: speech);
    await world.arrive(b);
    await world.drain(c, boundaries: [b.force]);
    final published = (await Archive.read(root.path)).heard.keys.single;
    final meta = File('${root.path}/${published.replaceAll('.wav', '.meta')}');
    final bytes = meta.readAsBytesSync();
    bytes[417 + bytes[416]] |= 0x01; // passthrough
    meta.writeAsBytesSync(bytes);
    File('${root.path}/$published').deleteSync();
    final day = localDateOf(start);
    expect(localDateOf(b.key.timerStart * 1000), isNot(day));
    expect(await actions.deleteDay(day, nowMs: 42), [published.replaceAll('.wav', '.meta')],
        reason: 'what was deleted, for the connectors: the meta passthrough left');
    expect((await ledgerOf(root.path))[b.key]!.tombstone, isNotNull);
    b.frames(200, p: speech);
    await world.arrive(b);
    await expectNothingPublished(world, c, boundaries: [b.force]);
    expect(await RawBinGate(c).release(), {b.key});
  });

  group('Delete Day and midnight: what crosses it stays exactly as it is', () {
    final eleven59 = DateTime(2026, 9, 11, 23, 59).millisecondsSinceEpoch;
    final day = localDateOf(eleven59), next = localDateOf(eleven59 + 120000);

    /// A conversation from 23:59 to 00:02 in three one-minute files (the first dated the
    /// day before midnight), and an earlier one wholly inside that day.
    Future<(Bin, List<Bin>)> twoConversations({double p = speech, bool taps = false}) async {
      final earlier = Bin(DateTime(2026, 9, 11, 10).millisecondsSinceEpoch, session: 3)..frames(150, p: speech);
      if (taps) earlier.tap();
      earlier.frames(150, p: speech);
      final a = Bin(eleven59, session: 4)..frames(3000, p: p);
      // A tap half a minute after midnight, in the conversation that crosses it.
      final b = a.next()..frames(1500, p: p);
      if (taps) b.tap();
      b.frames(1500, p: p);
      final d = b.next()..frames(3000, p: p);
      for (final x in [earlier, a, b, d]) {
        await world.arrive(x);
      }
      return (earlier, [a, b, d]);
    }

    Future<bool> tombstoned(Bin b) async => (await ledgerOf(root.path))[b.key]?.tombstone != null;

    test('a recording that runs past midnight stays, with its raw files and markers; the rest of the day goes',
        () async {
      final (earlier, crossing) = await twoConversations(taps: true);
      await world.drain(c, boundaries: [earlier.force, crossing.last.force]);
      final before = await Archive.read(root.path);
      final kept = before.heard.keys.singleWhere((k) => k.contains('$eleven59'));
      expect(await actions.deleteDay(day, nowMs: 1), [
        for (final k in before.heard.keys)
          if (k != kept) k
      ]);
      final after = await Archive.read(root.path);
      expect(after.heard.keys, [kept]);
      expect(after.heard[kept]!.length, 9000, reason: 'all three minutes');
      expect(before.edls.length, 2);
      expect([for (final e in after.edls) e['segmentFilename']], [kept.split('/').last],
          reason: "its marker stays; the deleted recording's goes");
      expect(await tombstoned(earlier), isTrue);
      for (final b in crossing) {
        expect(await tombstoned(b), isFalse, reason: b.key.stem);
      }
      await expectNothingPublished(world, c, boundaries: [earlier.force, crossing.last.force]);
    });

    test('when only what runs past midnight is left, Delete Day again deletes it; its raw files stay', () async {
      final (earlier, crossing) = await twoConversations(taps: true);
      await world.drain(c, boundaries: [earlier.force, crossing.last.force]);
      await actions.deleteDay(day, nowMs: 1);
      final kept = (await Archive.read(root.path)).heard.keys.single;
      expect(await actions.deleteDay(day, nowMs: 2), [kept]);
      final after = await Archive.read(root.path);
      expect(after.heard, isEmpty);
      expect(after.edls, isEmpty, reason: 'its marker goes with it');
      expect(Directory('${root.path}/recordings/$day').existsSync(), isFalse);
      for (final b in crossing) {
        expect(await tombstoned(b), isFalse, reason: '${b.key.stem}: not tombstoned, still owned by what was saved');
      }
      await expectNothingPublished(world, c, boundaries: [earlier.force, crossing.last.force]);
    });

    test('a deleted discard of the day in a file that stays is handed on, so the file can go', () async {
      // One file: a recording and a discard inside the day, then a recording across midnight.
      final a = Bin(DateTime(2026, 9, 11, 23, 50).millisecondsSinceEpoch, session: 5)
        ..frames(600, p: speech)
        ..frames(26400, p: quiet)
        ..frames(6000, p: speech);
      await world.arrive(a);
      await world.drain(c, boundaries: [a.force]);
      final before = await Archive.read(root.path);
      expect(before.heard, hasLength(2));
      expect(before.discards, isNotEmpty);
      await actions.deleteDay(day, nowMs: 1);
      final after = await Archive.read(root.path);
      expect(after.heard.keys.single, contains('recording_'), reason: 'the one across midnight');
      expect(after.discards, isEmpty);
      expect(await tombstoned(a), isFalse, reason: 'it holds audio after midnight');
      expect(await RawBinGate(c).release(), {a.key}, reason: 'everything in it is owned for good');
    });

    test('deleting the day it ends leaves it too, raw files included', () async {
      final (earlier, crossing) = await twoConversations();
      await world.drain(c, boundaries: [earlier.force, crossing.last.force]);
      await actions.deleteDay(next, nowMs: 1);
      expect((await Archive.read(root.path)).heard.length, 2);
      for (final b in crossing) {
        expect(await tombstoned(b), isFalse, reason: b.key.stem);
      }
    });

    test('a conversation still in progress across midnight is left to finish, under the day it started', () async {
      final (earlier, crossing) = await twoConversations();
      // Only the earlier conversation is closed; the planner has the other one open, so
      // the caller keeps its files.
      await world.drain(c, boundaries: [earlier.force]);
      await actions.deleteDay(day, nowMs: 1, keep: {for (final b in crossing) b.key});
      for (final b in crossing) {
        expect(await tombstoned(b), isFalse, reason: b.key.stem);
      }
      await world.drain(c, boundaries: [crossing.last.force]);
      final after = await Archive.read(root.path);
      expect(after.heard.keys.single, 'recordings/$day/recording_$eleven59.wav');
      expect(after.heard.values.single.length, 9000);
    });

    test('a discard that runs past midnight stays recoverable, whichever day is deleted', () async {
      final (earlier, crossing) = await twoConversations(p: quiet);
      await world.drain(c, boundaries: [earlier.force, crossing.last.force]);
      // Two minutes of quiet from 23:59 make one discard across midnight (then the third
      // minute another, wholly on the next day).
      final discard = (await Archive.read(root.path)).discards.singleWhere((d) => d['startMs'] == eleven59);
      expect(discard['endMs']! as int, greaterThan(DateTime(2026, 9, 12).millisecondsSinceEpoch));
      await actions.deleteDay(next, nowMs: 1);
      await actions.deleteDay(day, nowMs: 1);
      expect((await Archive.read(root.path)).discards.single['id'], discard['id']);
      final result = await recover([discard['id']! as String]);
      expect(result.stop, RecoverStop.recovered);
      expect((await Archive.read(root.path)).heard[result.published]!.length, 6000);
    });
  });

  test('Delete Day releases its set-aside files but keeps other days set aside', () async {
    final b = Bin(1789100000000)..frames(20, p: speech);
    final other = Bin(1789100000000 + 86400000, session: 8)..frames(20, p: speech);
    for (final bin in [b, other]) {
      await world.arrive(bin);
      await actions.setAside(bin.key);
    }
    await actions.deleteDay(localDateOf(b.key.timerStart * 1000), nowMs: 42);
    expect((await c.ledger.loadStream()).setAside, [other.key]);
    expect(await RawBinGate(c).release(), {b.key});
    expect((await c.store.load(other.key)).chunks, isNotEmpty);
  });

  test('Delete Day during a sync: a file still on its first transfer, and one not arrived yet, never come back',
      () async {
    final day = localDateOf(1789100000000);
    final b = Bin(1789100000000)..frames(300, p: speech);
    final notYet = Bin(1789100000000 + 600 * 1000, session: 8)..frames(300, p: speech);
    // The first transfer is running: a part, nothing sealed.
    final part = world.store.partFile(b.key, 0);
    await part.parent.create(recursive: true);
    await part.writeAsBytes(b.bytes);
    await actions.deleteDay(day, nowMs: 1, listed: [notYet.key]);
    final ledger = await ledgerOf(root.path);
    expect(ledger[b.key]!.tombstone, isNotNull);
    expect(ledger[notYet.key]!.tombstone, isNotNull);
    // The transfer finishes and seals; the other file arrives.
    await part.delete();
    await world.arrive(b);
    await world.arrive(notYet);
    await expectNothingPublished(world, c, boundaries: [b.force, notYet.force]);
    expect(Directory('${root.path}/recordings/$day').existsSync(), isFalse);
    expect(await RawBinGate(c).release(), {b.key, notYet.key});
  });

  test('Delete for a raw or set-aside file, and Try again', () async {
    final b = Bin(1789100000000)..frames(10, p: speech);
    await world.arrive(b);
    await saveCard(c.store, world.cards[b.key]!);
    await actions.setAside(b.key);
    expect((await c.ledger.loadStream()).setAside, [b.key]);
    await actions.tryAgain(b.key);
    expect((await c.ledger.loadStream()).setAside, isEmpty);
    expect(cardFileFor(c.store, b.key).existsSync(), isFalse, reason: 'built again from its chunks');
    await actions.setAside(b.key);
    await actions.deleteRawFile(b.key, nowMs: 7);
    expect((await c.ledger.loadStream()).setAside, isEmpty);
    expect((await ledgerOf(root.path))[b.key]!.tombstone!.atMs, 7);
  });

  test('Force and the cap history are recorded once each', () async {
    const k = RawFileKey(1789100000, 7);
    await actions.force([const PlanBoundary(BoundaryKind.force, k, 100)]);
    await actions.force([const PlanBoundary(BoundaryKind.force, k, 100)]);
    await actions.recordCap(atMs: 1, minutes: 120);
    await actions.recordCap(atMs: 1, minutes: 120);
    await actions.recordCap(atMs: 5, minutes: 30);
    // Recorded after, dated before: the phone's clock stepped back.
    await actions.recordCap(atMs: 3, minutes: 60);
    final s = await c.ledger.loadStream();
    expect(s.boundaries.length, 1);
    expect(s.caps, [(atMs: 1, minutes: 120), (atMs: 3, minutes: 60), (atMs: 5, minutes: 30)]);
    expect(CapHistory(s.caps).capMsAt(4), CapHistory.constant(60).capMsAt(0));
  });

  test('Delete Phone Conversations: the archive goes, and nothing is published again', () async {
    final a = await conversationThenQuiet();
    final b = Bin(1789100000000 + 86400 * 1000, session: 8)
      ..frames(200, p: speech)
      ..tap();
    await world.arrive(b);
    await world.drain(c, boundaries: [a.force]);
    await actions.deletePhoneConversations();
    expect(Directory('${root.path}/recordings').existsSync(), isFalse);
    await expectNothingPublished(world, c, boundaries: [a.force, b.force]);
    expect(await RawBinGate(c).release(), {a.key, b.key});
  });

  test('Delete Phone Segments: raw gone, receipts kept, a copy restored later never processed', () async {
    final a = await conversationThenQuiet();
    await world.drain(c, boundaries: [a.force]);
    await actions.deletePhoneSegments(nowMs: 3);
    expect(Directory('${root.path}/raw_segments').existsSync(), isFalse);
    final entry = (await ledgerOf(root.path))[a.key]!;
    expect(entry.tombstone, isNotNull);
    expect(entry.receipt!.length, a.length);
    await world.arrive(a);
    await expectNothingPublished(world, c, boundaries: [a.force]);
  });

  test('Reprocess all: a released file whose copy is put back is planned from it again', () async {
    final a = Bin(1789100000000)..frames(300, p: speech);
    await world.arrive(a);
    await world.drain(c, boundaries: [a.force]);
    expect(await RawBinGate(c).release(), {a.key});
    final receipt = (await ledgerOf(root.path))[a.key]!.receipt!;
    // Adjustment Mode's copy, back on the phone as the update adopts a bin.
    File('${root.path}/raw_segments/${a.key.rel}')
      ..createSync(recursive: true)
      ..writeAsBytesSync(a.bytes);
    await world.store.adoptLegacy(a.key,
        lifecycle: receipt.lifecycle,
        advertisedLength: receipt.advertisedLength,
        firstSealedAtMs: receipt.firstSealedAtMs);
    await actions.reprocessAll(restored: {a.key});
    expect((await ledgerOf(root.path))[a.key]!.receipt, isNull);
    await world.drain(c);
    final heard = (await Archive.read(root.path)).heard.values.single;
    expect([for (final h in heard) h.$1], [for (var i = 0; i < 300; i++) (frameTag(a.key), i)]);
  });

  test('Reprocess all: everything but tombstones is published again; old jobs are dropped', () async {
    final a = await conversationThenQuiet();
    final gone = await conversationThenQuiet(start: 1789100000000 + 86400 * 1000, session: 8);
    // A job's plan, made before the reset and published after it.
    final stalePlan = await world.drain(c, boundaries: [a.force, gone.force], pick: (_) => false);
    expect(stalePlan.items, isNotEmpty);
    await world.drain(c, boundaries: [a.force, gone.force]);
    final first = await Archive.read(root.path);
    await actions.deleteDiscards([first.discards.first['id']! as String]);
    await actions.deleteRawFile(gone.key, nowMs: 1);
    final generation = await actions.reprocessAll();
    expect(generation, 1);
    expect(Directory('${root.path}/recordings').existsSync(), isFalse);
    final s = await c.ledger.loadStream();
    expect(s.boundaries.where((b) => b.kind == BoundaryKind.rebuildEnd).length, 2);
    final report = await PublishJob(coordinator: c, newDecoder: FakeOpus.new, freeBytes: () async => null).publish(
      items: stalePlan.items,
      generation: 0,
      files: {for (final f in await world.planFiles()) f.key: f},
      cards: world.cards,
      settings: settings,
    );
    expect(report.stop, PublishStop.stale);
    expect(Directory('${root.path}/recordings').existsSync(), isFalse);
    // The rebuild: the stream's rebuild ends close it.
    await world.drain(c);
    final again = await Archive.read(root.path);
    Set<int> tagsOf(Archive x) => {for (final h in x.heard.values) ...h.map((f) => f.$1.$1)};
    expect(tagsOf(again), {frameTag(a.key)}, reason: 'the tombstoned file stays deleted');
    expect(again.heard.length, 1);
    expect(again.discards.length, 1, reason: 'the deleted discard is back (a derived deletion)');
  });

  test('Save original file: the logical file, across its chunks', () async {
    final b = Bin(1789100000000)..frames(100, p: speech);
    await world.arrive(b, upTo: b.frameOffsetsWritten[40]);
    await world.arrive(b);
    expect((await c.store.load(b.key)).chunks.length, 2);
    final out = File('${root.path}/export.bin');
    await actions.exportRaw(b.key, out);
    expect(out.readAsBytesSync(), b.bytes);
  });
}
