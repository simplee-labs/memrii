import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/raw/actions.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
import 'package:omi/services/raw/pipeline.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';

import 'plan_fixtures.dart';
import 'publish_fixtures.dart';

/// Cards from the world's bins, over the bytes sealed so far; [failing] files fail.
class _Cards implements CardSource {
  final World world;
  final Set<RawFileKey> failing = {};
  _Cards(this.world);

  @override
  Future<FileCard> current(RawFileKey key) async {
    if (failing.contains(key)) throw CardBuildFailed(key, 'the test fails it');
    final file = await world.store.load(key);
    final records = parseRecords(await file.read(0, file.length));
    final whole = world.bins[key]!.file().audio!;
    final n = records.frameCount;
    return FileCard(
      key: key,
      indexerVersion: cardIndexerVersion,
      chunks: [for (final c in file.chunks) (c.offset, c.length)],
      records: records,
      decoderId: 'fake',
      vadModelId: 'fake-vad',
      audio: FrameAudio(
          decoded: Uint8List.fromList(whole.decoded.sublist(0, n)),
          speech: Float32List.fromList(whole.speech.sublist(0, n))),
    );
  }
}

/// SetAsideBins' rules in memory: one failure count, for one file at a time (another
/// file's failure starts it again), three in a row set the file aside.
class _Book implements SetAsideBook {
  final Set<RawFileKey> entries = {};
  RawFileKey? failing;
  int failures = 0;
  final Set<RawFileKey> due = {};

  @override
  Set<RawFileKey> listed() => {...entries};

  @override
  Future<void> list(RawFileKey key) async => entries.add(key);

  @override
  void unlist(RawFileKey key) {
    entries.remove(key);
    if (failing == key) failing = null;
    due.remove(key);
  }

  @override
  Future<bool> recordFailure(RawFileKey key) async {
    failures = failing == key ? failures + 1 : 1;
    failing = key;
    if (failures < 3) return false;
    failing = null;
    return true;
  }

  @override
  void recordSuccess(Iterable<RawFileKey> keys) {
    if (keys.contains(failing)) failing = null;
  }

  @override
  Set<RawFileKey> retryDue() => {...due};
}

void main() {
  late Directory root;
  late World world;
  late OwnershipCoordinator c;
  late ArchiveActions actions;
  late _Cards cards;
  late _Book book;
  int? free;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pipeline_');
    world = World(root);
    c = OwnershipCoordinator(root.path);
    actions = ArchiveActions(c);
    cards = _Cards(world);
    book = _Book();
    free = null;
  });
  tearDown(() => root.deleteSync(recursive: true));

  const settings = PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF', opusSidecar: true);

  RawPipeline pipeline() => RawPipeline(
        coordinator: c,
        actions: actions,
        gate: RawBinGate(c),
        cards: cards,
        book: book,
        newJob: () => PublishJob(coordinator: c, newDecoder: FakeOpus.new, freeBytes: () async => free),
      );

  Future<PassReport> pass(
          {List<({int sessionId, int atMs})> anchors = const [],
          Set<int> knownEnded = const {},
          ({int atMs, int? liveSession})? listing,
          QuietMark? quiet,
          int? nowMs,
          List<RawFileKey> missing = const [],
          bool planOnly = false}) =>
      pipeline().run(
          PassInputs(
            policies: const PolicyHistory(autoPolicy),
            capMinutesNow: 120,
            settings: settings,
            nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
            anchors: anchors,
            knownEnded: knownEnded,
            listing: listing,
            quiet: quiet,
            missing: missing,
          ),
          planOnly: planOnly);

  Future<bool> onPhone(Bin b) async => (await world.store.load(b.key)).chunks.isNotEmpty;

  const t0 = 1789100000000;

  test('a pass publishes what closed and releases what it owns whole; what is open waits', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    await world.arrive(a);
    await world.arrive(b);
    final report = await pass();
    expect(report.stop, PassStop.done);
    expect(report.published, 1);
    expect(report.open.single.frameCount, 300);
    expect(report.released, {a.key});
    expect(await onPhone(a), isFalse);
    expect(await onPhone(b), isTrue, reason: 'its conversation is open');
    final heard = (await Archive.read(root.path)).heard.values.single;
    expect([for (final h in heard) h.$1], [for (var i = 0; i < 300; i++) (frameTag(a.key), i)]);
  });

  test('a pass reports its progress: half as it indexes the files, the rest as it renders', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    await world.arrive(a);
    await world.arrive(b);
    final shown = <double>[];
    final report = await pipeline().run(
        PassInputs(
          policies: const PolicyHistory(autoPolicy),
          capMinutesNow: 120,
          settings: settings,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        ),
        onProgress: shown.add);
    expect(report.published, 1);
    expect(shown, [0.25, 0.5, 1.0], reason: 'a indexed, b indexed, a\'s recording rendered');
  });

  test('a later pass plans against the receipts of released files and carries on', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    await world.arrive(a);
    await world.arrive(b);
    await pass();
    final d = b.next()..frames(300, p: speech);
    await world.arrive(d);
    expect((await pass()).open.single.frameCount, 600, reason: 'one conversation across both files');
    await actions.force([d.force]);
    final report = await pass();
    expect(report.published, 1);
    expect(report.released, {b.key, d.key});
    final archive = await Archive.read(root.path);
    expect(archive.heard.length, 2);
    expect(archive.heard.values.last.map((h) => h.$1), [
      for (var i = 0; i < 300; i++) (frameTag(b.key), i),
      for (var i = 0; i < 300; i++) (frameTag(d.key), i),
    ]);
    expect((await pass()).published, 0, reason: 'nothing published twice');
  });

  test("a released file's mute-on still governs: its muted interval is listed when it ends", () async {
    final a = Bin(t0)
      ..frames(300, p: speech)
      ..muteOn();
    await world.arrive(a);
    final first = await pass();
    expect(first.published, 1);
    expect(first.released, {a.key}, reason: 'its audio is saved; the open mute need not be');
    final b = a.next(gapMs: 60000)
      ..muteOff()
      ..frames(300, p: speech);
    await world.arrive(b);
    await actions.force([b.force]);
    await pass();
    final reasons = [for (final d in (await Archive.read(root.path)).discards) d['reason']];
    expect(reasons, ['muted'], reason: "the mute-on is known only from a's receipt");
  });

  test('a Priority Recording started before the Omi had the time stays on once its first files are released', () async {
    // The Omi restarted without the time, so its first file is named by uptime; Priority
    // Recording started in it, the phone then set the time, and a Force Sync saved what
    // was there.
    final pre = Bin(t0 - 6000, keySeconds: 100, headerUtcMs: 0)
      ..priority(atMs: 0)
      ..frames(300, p: speech);
    final utc = Bin(t0, uptimeMs: pre.uptimeMs)..frames(50, p: speech);
    await world.arrive(pre);
    await world.arrive(utc);
    await actions.force([utc.force]);
    const now = t0 + 3600000;
    expect((await pass(nowMs: now)).released, {pre.key, utc.key});
    final quietOn = utc.next()..frames(500, p: quiet);
    await world.arrive(quietOn);
    final report = await pass(nowMs: now);
    expect(report.open.single.inPriority, isTrue, reason: "the priority start is known only from pre's receipt");
    expect(report.open.single.frameCount, 500, reason: 'in Priority Recording, quiet audio is kept');
  });

  test('two files failing: one strike a pass, on the first, so it is set aside after three', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    final d = b.next(gapMs: 300000)..frames(300, p: speech);
    for (final x in [a, b, d]) {
      await world.arrive(x);
    }
    cards.failing.addAll([b.key, d.key]);
    for (var i = 0; i < 3; i++) {
      await pass();
    }
    expect(book.listed(), {b.key}, reason: "the count is one file's: b's strikes are not reset by d's");
  });

  test('a session the phone saw live before the last one has ended, however late its files arrive', () async {
    final a = Bin(t0, session: 7)..frames(300, p: speech);
    final later = DateTime.now().millisecondsSinceEpoch - 1000;
    await world.arrive(a); // sealed after both anchors were read
    final anchors = [(sessionId: 7, atMs: later - 5000), (sessionId: 8, atMs: later)];
    final r = await pass(anchors: anchors, listing: (atMs: later, liveSession: null));
    expect(r.published, 1);
    expect(r.ended, {7});
  });

  test('a session found ended stays ended without its anchor', () async {
    final a = Bin(t0, session: 7)..frames(300, p: speech);
    await world.arrive(a);
    expect((await pass(knownEnded: {7})).published, 1);
  });

  test('plan only: the plan as it stands, nothing published, counted or released', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    final d = b.next(gapMs: 300000)..frames(300, p: speech);
    for (final x in [a, b, d]) {
      await world.arrive(x);
    }
    cards.failing.add(d.key);
    final r = await pass(planOnly: true);
    expect(r.plan!.items.whereType<PlannedRecording>(), isNotEmpty, reason: 'a closed');
    expect(r.published, 0);
    expect(r.released, isEmpty);
    expect(book.failing, isNull);
    expect((await Archive.read(root.path)).heard, isEmpty);
    expect(await onPhone(a), isTrue);
  });

  test('a file whose card keeps failing is a hole until the third failure sets it aside', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    final d = b.next(gapMs: 300000)..frames(300, p: speech);
    for (final x in [a, b, d]) {
      await world.arrive(x);
    }
    cards.failing.add(b.key);
    for (var i = 1; i <= 2; i++) {
      final r = await pass();
      expect(r.unindexed, {b.key});
      expect(r.published, 0, reason: 'pass $i: a waits for what follows it');
    }
    final r = await pass();
    expect(r.published, 1, reason: 'set aside, b is a wall: a closes; d stays open');
    expect(book.listed(), {b.key});
    expect((await c.ledger.loadStream()).setAside, [b.key]);
    expect(await onPhone(b), isTrue, reason: 'a set-aside file stays');
  });

  test('the page\'s set-aside list follows the ledger', () async {
    final a = Bin(t0)..frames(300, p: speech);
    await world.arrive(a);
    await actions.setAside(a.key);
    await pass();
    expect(book.listed(), {a.key});
    await actions.deleteRawFile(a.key, nowMs: 1);
    final r = await pass();
    expect(book.listed(), isEmpty);
    expect(r.released, {a.key});
  });

  test('a newer build tries a set-aside file once more', () async {
    final a = Bin(t0)..frames(300, p: speech);
    await world.arrive(a);
    await actions.setAside(a.key);
    await pass();
    book.due.add(a.key);
    await pass();
    expect((await c.ledger.loadStream()).setAside, isEmpty);
    expect(book.listed(), isEmpty);
  });

  test('a session the Omi has left closes its last conversation', () async {
    final a = Bin(t0, session: 7)..frames(300, p: speech);
    await world.arrive(a);
    expect((await pass()).published, 0);
    final later = DateTime.now().millisecondsSinceEpoch + 1000;
    final listing = (atMs: later, liveSession: null);
    expect((await pass(anchors: [(sessionId: 7, atMs: later)], listing: listing)).published, 0,
        reason: 'still the live session');
    final r = await pass(anchors: [(sessionId: 8, atMs: later)], listing: listing);
    expect(r.published, 1);
    expect(r.released, {a.key});
  });

  test('a session first seen after the Omi reported another one is not taken as ended', () async {
    final a = Bin(t0, session: 9)..frames(300, p: speech);
    await world.arrive(a);
    expect((await pass(anchors: [(sessionId: 8, atMs: 1)], listing: (atMs: 1, liveSession: null))).published, 0);
  });

  test("a list of the Omi's files older than its last session read ends nothing: it may lack the last file", () async {
    final a = Bin(t0, session: 7)..frames(300, p: speech);
    await world.arrive(a);
    final read = DateTime.now().millisecondsSinceEpoch + 1000;
    final anchors = [(sessionId: 7, atMs: read - 60000), (sessionId: 8, atMs: read)];
    expect((await pass(anchors: anchors)).published, 0, reason: 'no list taken since the app started');
    final stale = await pass(anchors: anchors, listing: (atMs: read - 1, liveSession: null));
    expect(stale.published, 0, reason: 'listed while 7 may still have been writing a file');
    expect(stale.ended, isEmpty);
    final r = await pass(anchors: anchors, listing: (atMs: read, liveSession: null));
    expect(r.published, 1);
    expect(r.ended, {7});
  });

  test('a session the phone never saw live has ended once a list is taken on a link to another session', () async {
    final a = Bin(t0, session: 7)..frames(300, p: speech);
    await world.arrive(a);
    final now = DateTime.now().millisecondsSinceEpoch;
    expect((await pass(listing: (atMs: now, liveSession: 7))).published, 0, reason: 'the live session');
    final r = await pass(listing: (atMs: now, liveSession: 8));
    expect(r.published, 1);
    expect(r.ended, {7});
    expect(r.released, {a.key});
  });

  test('the quiet mark closes the conversation still open, and its files go', () async {
    final a = Bin(t0)..frames(300, p: speech);
    await world.arrive(a);
    expect((await pass(quiet: quietAfter(a, 100000))).published, 0, reason: 'no split yet');
    final r = await pass(quiet: quietAfter(a, 200000));
    expect(r.published, 1);
    expect(r.open, isEmpty);
    expect(r.released, {a.key});
    expect(recordingsOf(r.plan!), isEmpty, reason: 'the last plan, after publishing, has nothing left');
  });

  test("an ended session's last conversation waits for its files still on the Omi", () async {
    final a = Bin(t0, session: 7)..frames(300, p: speech);
    final b = a.next()..frames(300, p: speech);
    final elsewhere = Bin(t0 + 7200000, session: 9); // a session with files only on the list
    await world.arrive(a);
    final listing = (atMs: DateTime.now().millisecondsSinceEpoch, liveSession: 8);
    final r = await pass(listing: listing, missing: [b.key, elsewhere.key]);
    expect(r.ended, {7, 9}, reason: 'every session but the one the list was taken in, here or on the list');
    expect(r.published, 0, reason: 'the file still on the Omi may carry the conversation on');
    await world.arrive(b);
    final done = await pass(listing: listing);
    expect(done.published, 1);
    expect(done.released, {a.key, b.key});
  });

  test('a pass expires discards whose window has passed', () async {
    final a = Bin(t0)
      ..frames(300, p: speech)
      ..resume(200000)
      ..frames(50, p: quiet);
    await world.arrive(a);
    await actions.force([a.force]);
    await pass();
    final discard = (await Archive.read(root.path)).discards.single;
    expect(await onPhone(a), isTrue, reason: 'the discard keeps its audio');
    final r = await pass(nowMs: (discard['endMs']! as int) + 48 * 3600 * 1000);
    expect(r.expired, 1);
    expect((await Archive.read(root.path)).discards, isEmpty);
    expect(r.released, {a.key});
  });

  test('without space to render, nothing is published and the files stay', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    await world.arrive(a);
    await world.arrive(b);
    free = 0;
    final r = await pass();
    expect(r.stop, PassStop.storageFull);
    expect(r.published, 0);
    expect(await onPhone(a), isTrue);
  });

  test('a damaged file is set aside once everything readable in it is saved', () async {
    final a = Bin(t0)..frames(300, p: speech);
    await world.arrive(a, upTo: a.length);
    // Unreadable bytes after the audio, then the transfer completes.
    final part = world.store.partFile(a.key, a.length);
    await part.writeAsBytes(Uint8List.fromList(List.filled(24, 0xEE)), flush: true);
    await world.store.seal(a.key,
        appendOffset: a.length, keepLength: 24, provenance: ChunkProvenance.echoed, advertisedLength: a.length + 24);
    await world.store.setLifecycle(a.key, SourceLifecycle.complete, advertisedLength: a.length + 24);
    var r = await pass();
    expect(book.listed(), isEmpty, reason: 'its audio is open, not saved yet');
    await actions.force([PlanBoundary(BoundaryKind.force, a.key, a.length + 24)]);
    r = await pass();
    expect(r.published, 1);
    expect(book.listed(), {a.key});
    expect(r.released, isEmpty, reason: 'kept for Save original file');
    expect(await onPhone(a), isTrue);
  });

  test('a file the Omi lists that has not arrived is a hole', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    final d = b.next(gapMs: 300000)..frames(300, p: speech);
    await world.arrive(a);
    await world.arrive(d);
    expect((await pass(missing: [b.key])).published, 0, reason: 'a waits for b');
    expect((await pass()).published, 1);
  });
}
