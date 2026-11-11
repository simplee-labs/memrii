import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/raw/actions.dart';
import 'package:omi/services/raw/archive_files.dart';
import 'package:omi/services/raw/card.dart';
import 'package:omi/services/raw/card_audio.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
import 'package:omi/services/raw/ledger.dart';
import 'package:omi/services/raw/legacy_update.dart';
import 'package:omi/services/raw/pipeline.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/publish_job.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/set_aside_bins.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_fixtures.dart';
import 'publish_fixtures.dart';

class _MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? docs;
  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
}

/// Cards from the bins written, over the bytes on the phone.
class _Cards implements CardSource {
  final Map<RawFileKey, Bin> bins;
  final RawChunkStore store;
  _Cards(this.bins, this.store);

  @override
  Future<FileCard> current(RawFileKey key) async {
    final file = await store.load(key);
    final records = parseRecords(await file.read(0, file.length));
    final whole = bins[key]!.file().audio!;
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

class _Book implements SetAsideBook {
  final Set<RawFileKey> entries = {};
  @override
  Set<RawFileKey> listed() => {...entries};
  @override
  Future<void> list(RawFileKey key) async => entries.add(key);
  @override
  void unlist(RawFileKey key) => entries.remove(key);
  @override
  Future<bool> recordFailure(RawFileKey key) async => false;
  @override
  void recordSuccess(Iterable<RawFileKey> keys) {}
  @override
  Set<RawFileKey> retryDue() => const {};
}

void main() {
  late Directory root;
  late OwnershipCoordinator c;
  final bins = <RawFileKey, Bin>{};

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    root = Directory.systemTemp.createTempSync('legacy_update_');
    PathProviderPlatform.instance = _MockPathProvider()..docs = root.path;
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    SetAsideBins.currentBuild = () async => '18';
    c = OwnershipCoordinator(root.path);
    bins.clear();
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A bin as today's pipeline leaves it: whole, without a manifest.
  File legacyBin(Bin b, {String under = 'raw_segments'}) {
    bins[b.key] = b;
    final f = File('${root.path}/$under/${b.key.rel}')..createSync(recursive: true);
    f.writeAsBytesSync(b.bytes);
    return f;
  }

  /// A recording's meta naming [named], as today's pipeline writes it.
  void recordingNaming(int startMs, List<RawFileKey> named, {String suffix = ''}) {
    final date = localDateOf(startMs);
    File('${root.path}/recordings/$date/recording_$startMs$suffix.meta')
      ..createSync(recursive: true)
      ..writeAsBytesSync(buildMeta(
        totalSamples: 16000,
        peaks: Uint16List(200),
        sessionId: 7,
        startUptimeSeconds: 100,
        uploadKey: null,
        forceSynced: false,
        capEnded: false,
        silero: true,
        manual: false,
        relativeBins: [for (final k in named) k.rel],
      ));
  }

  void discards(String date, List<Map<String, Object?>> records) {
    File('${root.path}/recordings/$date/discards.jsonl')
      ..createSync(recursive: true)
      ..writeAsStringSync('${records.map(jsonEncode).join('\n')}\n');
  }

  Future<void> update() => LegacyUpdate(c, capMinutesNow: 120).runOnce();

  Future<Map<RawFileKey, LedgerEntry>> ledger() async => c.ledger.entriesFor(bins.keys);

  const t0 = 1789100000000;

  test('a bin a recording names is owned whole by the legacy owner, markers included', () async {
    final a = Bin(t0)
      ..frames(100, p: speech)
      ..tap()
      ..frames(100, p: speech);
    final f = legacyBin(a);
    recordingNaming(t0, [a.key]);
    await update();
    final file = await c.store.load(a.key);
    expect(file.lifecycle, SourceLifecycle.complete);
    expect(file.firstSealedAtMs, f.lastModifiedSync().millisecondsSinceEpoch);
    final e = (await ledger())[a.key]!;
    expect(e.frames.single.owner, legacyOwner);
    expect((e.frames.single.start, e.frames.single.end), (0, a.length));
    expect(e.events.values.toSet(), {legacyOwner}, reason: 'the tap is not an orphan again');
    expect((await c.ledger.loadStream()).caps, [(atMs: 0, minutes: 120)]);
    expect(File('${root.path}/pipeline_update.json').existsSync(), isTrue);
  });

  test('discard ranges stay their discards\', with ids; a recording naming the bin owns the rest', () async {
    final a = Bin(t0)
      ..frames(100, p: speech)
      ..frames(50, p: quiet);
    legacyBin(a);
    recordingNaming(t0, [a.key]);
    final from = a.frameOffsetsWritten[100];
    final date = localDateOf(t0);
    discards(date, [
      {
        'startMs': t0 + 2000,
        'endMs': t0 + 3000,
        'reason': 'noise_silence_split',
        'maxVoiceProb': 0.1,
        'relativeBins': [a.key.rel],
        // As today's processor writes it: one flat [start, end] per file.
        'binRanges': {
          a.key.rel: [from, a.length]
        },
      }
    ]);
    await update();
    final line = jsonDecode(File('${root.path}/recordings/$date/discards.jsonl').readAsLinesSync().single) as Map;
    expect(line['id'], '${a.key.rel}@$from');
    final e = (await ledger())[a.key]!;
    expect([
      for (final r in e.frames) (r.start, r.end, r.owner)
    ], [
      (0, from, legacyOwner),
      (from, a.length, Owner(OwnerKind.discard, '${a.key.rel}@$from')),
    ]);
    // Delete Discard works on it, as on any discard.
    expect(await ArchiveActions(c).deleteDiscards(['${a.key.rel}@$from']), 1);
  });

  test('deleted bins are tombstoned, drafts finished, old state removed; unnamed audio stays unowned', () async {
    final a = Bin(t0)..frames(100, p: speech);
    final b = Bin(t0 + 600000)..frames(100, p: speech);
    legacyBin(a);
    legacyBin(b);
    File('${root.path}/deleted_bins.json').writeAsStringSync(jsonEncode([a.key.rel]));
    File('${root.path}/vad_checkpoint.json').writeAsStringSync('{}');
    recordingNaming(t0 + 900000, const [], suffix: '_draft');
    await update();
    final l = await ledger();
    expect(l[a.key]!.tombstone?.reason, 'update');
    expect(l[b.key], isNull);
    final date = localDateOf(t0 + 900000);
    expect(File('${root.path}/recordings/$date/recording_${t0 + 900000}.meta').existsSync(), isTrue);
    expect(File('${root.path}/recordings/$date/recording_${t0 + 900000}_draft.meta').existsSync(), isFalse);
    for (final name in ['deleted_bins.json', 'vad_checkpoint.json']) {
      expect(File('${root.path}/$name').existsSync(), isFalse, reason: name);
    }
  });

  test('a deleted recording\'s set-aside bin keeps its unsaved audio, and Try again saves it', () async {
    // Today's processor saved a recording from the file's first 100 frames, then failed;
    // the user deleted that recording, so `deleted_bins.json` names the file.
    final a = Bin(t0)..frames(300, p: speech);
    legacyBin(a);
    final at = a.frameOffsetsWritten[100];
    SharedPreferencesUtil().setAsideBins = jsonEncode([
      SetAsideBin(relBin: a.key.rel, build: '18', automatic: true, atMs: 1, startByte: at).toJson(),
    ]);
    File('${root.path}/deleted_bins.json').writeAsStringSync(jsonEncode([a.key.rel]));
    await update();
    final e = (await ledger())[a.key]!;
    expect(e.tombstone, isNull);
    expect([for (final r in e.frames) (r.start, r.end, r.owner)], [(0, at, legacyOwner)]);
    expect((await c.ledger.loadStream()).setAside, [a.key]);
    final actions = ArchiveActions(c);
    await actions.tryAgain(a.key);
    await actions.force([a.force]);
    final report = await RawPipeline(
      coordinator: c,
      actions: actions,
      gate: RawBinGate(c),
      cards: _Cards(bins, c.store),
      book: _Book(),
      newJob: () => PublishJob(coordinator: c, newDecoder: FakeOpus.new, freeBytes: () async => null),
    ).run(PassInputs(
      policies: const PolicyHistory(autoPolicy),
      capMinutesNow: 120,
      settings: const PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF'),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(report.published, 1);
    expect((await Archive.read(root.path)).heard.values.single.map((h) => h.$1),
        [for (var i = 100; i < 300; i++) (frameTag(a.key), i)]);
  });

  test('a deleted recording\'s bin that holds a discard stays for it until the discard expires', () async {
    final a = Bin(t0)
      ..frames(100, p: speech)
      ..frames(50, p: quiet);
    legacyBin(a);
    final from = a.frameOffsetsWritten[100];
    discards(localDateOf(t0), [
      {
        'startMs': t0 + 2000,
        'endMs': t0 + 3000,
        'reason': 'noise_silence_split',
        'maxVoiceProb': 0.1,
        'relativeBins': [a.key.rel],
        'binRanges': {
          a.key.rel: [from, a.length]
        },
      }
    ]);
    File('${root.path}/deleted_bins.json').writeAsStringSync(jsonEncode([a.key.rel]));
    await update();
    final e = (await ledger())[a.key]!;
    expect(e.tombstone, isNull);
    expect([
      for (final r in e.frames) (r.start, r.end, r.owner)
    ], [
      (0, from, legacyOwner),
      (from, a.length, Owner(OwnerKind.discard, '${a.key.rel}@$from')),
    ]);
    expect(await RawBinGate(c).release(), isEmpty, reason: 'Recover still needs it');
  });

  test('a set-aside bin a recording names is still owned only up to where its unsaved audio begins', () async {
    // Today's processor saved a recording from the file, then failed later in it.
    final a = Bin(t0)..frames(200, p: speech);
    legacyBin(a);
    recordingNaming(t0, [a.key]);
    final at = a.frameOffsetsWritten[120];
    SharedPreferencesUtil().setAsideBins = jsonEncode([
      SetAsideBin(relBin: a.key.rel, build: '17', automatic: true, atMs: 1, startByte: at).toJson(),
    ]);
    await update();
    final e = (await ledger())[a.key]!;
    expect([for (final r in e.frames) (r.start, r.end)], [(0, at)], reason: 'the 80 unsaved frames stay unowned');
  });

  test('a discard without ranges that owns several bins gets ranges for each, so Delete hands on them all', () async {
    final a = Bin(t0)..frames(50, p: quiet);
    final b = a.next()..frames(50, p: quiet);
    legacyBin(a);
    legacyBin(b);
    final date = localDateOf(t0);
    discards(date, [
      {
        'startMs': t0,
        'endMs': t0 + 2000,
        'reason': 'noise_silence_split',
        'maxVoiceProb': 0.1,
        'relativeBins': [a.key.rel, b.key.rel],
      }
    ]);
    await update();
    final line = jsonDecode(File('${root.path}/recordings/$date/discards.jsonl').readAsLinesSync().single) as Map;
    expect((line['binRanges'] as Map).keys.toSet(), {a.key.rel, b.key.rel});
    final id = line['id'] as String;
    expect(await ArchiveActions(c).deleteDiscards([id]), 1);
    final l = await ledger();
    for (final k in [a.key, b.key]) {
      expect(l[k]!.frames.single.owner, deletedDiscard, reason: k.stem);
    }
    expect(await RawBinGate(c).release(), {a.key, b.key});
  });

  test('a set-aside bin stays set aside, owned up to where its unsaved audio begins', () async {
    final a = Bin(t0)..frames(200, p: speech);
    legacyBin(a);
    final at = a.frameOffsetsWritten[120];
    SharedPreferencesUtil().setAsideBins = jsonEncode([
      SetAsideBin(relBin: a.key.rel, build: '17', automatic: true, atMs: 1, startByte: at).toJson(),
    ]);
    await update();
    expect((await c.ledger.loadStream()).setAside, [a.key]);
    final e = (await ledger())[a.key]!;
    expect((e.frames.single.start, e.frames.single.end), (0, at));
  });

  test('bins moved aside for discards come back to raw_segments', () async {
    final a = Bin(t0)..frames(50, p: quiet);
    legacyBin(a, under: 'discarded_segments');
    await update();
    expect(File('${root.path}/raw_segments/${a.key.rel}').existsSync(), isTrue);
    expect(File('${root.path}/discarded_segments/${a.key.rel}').existsSync(), isFalse);
  });

  test('it runs once', () async {
    final a = Bin(t0)..frames(100, p: speech);
    legacyBin(a);
    await update();
    File('${root.path}/deleted_bins.json').writeAsStringSync(jsonEncode([a.key.rel]));
    await update();
    expect((await ledger())[a.key]?.tombstone, isNull);
  });

  test('after it, a pass publishes only what today\'s pipeline had not, and releases the rest', () async {
    final a = Bin(t0)..frames(300, p: speech);
    final b = a.next(gapMs: 300000)..frames(300, p: speech);
    legacyBin(a);
    legacyBin(b);
    recordingNaming(t0, [a.key]);
    await update();
    final actions = ArchiveActions(c);
    await actions.force([b.force]);
    final report = await RawPipeline(
      coordinator: c,
      actions: actions,
      gate: RawBinGate(c),
      cards: _Cards(bins, c.store),
      book: _Book(),
      newJob: () => PublishJob(coordinator: c, newDecoder: FakeOpus.new, freeBytes: () async => null),
    ).run(PassInputs(
      policies: const PolicyHistory(autoPolicy),
      capMinutesNow: 120,
      settings: const PublishSettings(deviceId: 'AA:BB:CC:DD:EE:FF'),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    ));
    expect(report.published, 1);
    final heard = (await Archive.read(root.path)).heard;
    expect(heard.values.single.map((h) => h.$1), [for (var i = 0; i < 300; i++) (frameTag(b.key), i)],
        reason: 'b alone: a is the legacy recording\'s');
    expect(report.released, {a.key, b.key});
  });
}
