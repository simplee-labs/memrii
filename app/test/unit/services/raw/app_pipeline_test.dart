import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/raw/app_pipeline.dart';
import 'package:omi/services/raw/chunk_download.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
import 'package:omi/services/raw/pipeline.dart';
import 'package:omi/services/raw/plan.dart';
import 'package:omi/services/raw/raw_chunks.dart';
import 'package:omi/services/set_aside_bins.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/wal_file_manager.dart';
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

void main() {
  group('Delete Day keeps what crosses midnight, as the plan stands now', () {
    final midnight = DateTime(2026, 9, 12).millisecondsSinceEpoch;

    Plan planOf(List<Bin> bins) => plan(PlanInput(
          files: [for (final b in bins) b.file()],
          policies: const PolicyHistory(autoPolicy),
          caps: CapHistory.constant(120),
        ));

    test('a conversation open past midnight keeps its files', () {
      final a = Bin(midnight - 5000)..frames(600, p: speech);
      expect(AppPipeline.crossingMidnight(planOf([a]), midnight, {a.key}), {a.key});
    });

    test('one open before midnight keeps its files when its session has a file from midnight on', () {
      final a = Bin(midnight - 600000)..frames(300, p: speech);
      final later = RawFileKey(midnight ~/ 1000 + 30, a.key.sessionId);
      expect(AppPipeline.crossingMidnight(planOf([a]), midnight, {a.key, later}), {a.key, later},
          reason: 'its end is not known yet');
      expect(AppPipeline.crossingMidnight(planOf([a]), midnight, {a.key}), isEmpty,
          reason: 'nothing of its session after midnight: it is the day\'s');
    });

    test('a closed item not yet published that runs past midnight keeps its files', () {
      final a = Bin(midnight - 5000)
        ..frames(600, p: speech)
        ..resume(300000)
        ..frames(10, p: speech);
      final p = planOf([a]);
      expect(p.items.whereType<PlannedRecording>(), isNotEmpty);
      expect(AppPipeline.crossingMidnight(p, midnight, {a.key}), {a.key});
    });

    test('nothing is deleted when the plan was not made', () {
      expect(() => AppPipeline.keptByDeleteDay(const PassReport(PassStop.cancelled), midnight, {}, {}),
          throwsA(isA<StateError>()));
    });

    test('a file not arrived yet is kept when it starts close enough to midnight to run past it', () {
      final near = RawFileKey(midnight ~/ 1000 - 300, 7); // 23:55
      final early = RawFileKey(midnight ~/ 1000 - 1800, 7); // 23:30
      final after = RawFileKey(midnight ~/ 1000 + 60, 7); // the next day's
      final all = {near, early, after};
      expect(AppPipeline.keptByDeleteDay(const PassReport(PassStop.done), midnight, all, all), {near});
    });

    test('an open conversation that runs into such a file keeps its files too', () {
      final a = Bin(midnight - 1800000)..frames(300, p: speech); // 23:30
      final near = RawFileKey(midnight ~/ 1000 - 300, a.key.sessionId);
      final p = plan(PlanInput(
        files: [a.file()],
        missing: [near],
        policies: const PolicyHistory(autoPolicy),
        caps: CapHistory.constant(120),
      ));
      expect(p.open, isNotEmpty);
      expect(AppPipeline.keptByDeleteDay(PassReport(PassStop.done, plan: p), midnight, {a.key, near}, {near}),
          {a.key, near});
    });
  });

  group('startup and Reprocess all', () {
    late Directory root;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
      root = Directory.systemTemp.createTempSync('app_pipeline_');
      PathProviderPlatform.instance = _MockPathProvider()..docs = root.path;
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
      await WalFileManager.init();
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('a part a crash left is sealed at startup from the saved progress, before any listing', () async {
      final a = Bin(1789100000000)..frames(100, p: speech);
      final store = RawChunkStore(root.path);
      final part = store.partFile(a.key, 0);
      part.parent.createSync(recursive: true);
      part.writeAsBytesSync(a.bytes);
      // The transfer's progress was saved up to half of it; the Omi may since have
      // reclaimed the file, so no listing will name it again.
      final saved = a.length ~/ 2;
      await WalFileManager.saveWals([
        Wal(
            device: 'AA:BB',
            fileNum: 0,
            walOffset: saved,
            storageTotalBytes: a.length,
            timerStart: a.key.timerStart,
            sessionId: a.key.sessionId,
            storage: WalStorage.sdcard),
      ]);
      await AppPipeline.forTest().start();
      expect((await store.load(a.key)).length, saved);
      expect(part.existsSync(), isFalse);
    });

    test('is refused, with nothing changed, when the only raw file left is deleted', () async {
      final world = World(root);
      final a = Bin(1789100000000)..frames(100, p: speech);
      await world.arrive(a, upTo: a.length ~/ 2); // still receiving
      final app = AppPipeline.forTest();
      await app.start();
      await app.actions.deleteRawFile(a.key, nowMs: 1);
      await expectLater(app.prepareReprocess(), throwsA(isA<StateError>()));
    });

    test('is refused, with nothing changed, when the only raw files left are set aside', () async {
      SetAsideBins.currentBuild = () async => '18';
      final world = World(root);
      final a = Bin(1789100000000)..frames(100, p: speech);
      await world.arrive(a);
      final app = AppPipeline.forTest();
      await app.start();
      await app.setAside(a.key);
      await expectLater(app.prepareReprocess(), throwsA(isA<StateError>()),
          reason: 'the rebuild skips a set-aside file: nothing would be rebuilt');
    });

    test('Delete Day after a Stop still plans, and keeps a file still arriving that may run past midnight', () async {
      final start = DateTime(2026, 11, 10, 23, 58).millisecondsSinceEpoch;
      final b = Bin(start)..frames(6000, p: speech);
      final app = AppPipeline.forTest();
      await app.start();
      final part = app.coordinator.store.partFile(b.key, 0);
      part.parent.createSync(recursive: true);
      part.writeAsBytesSync(b.bytes); // its first transfer, not sealed yet
      app.cancel(); // Stop, with no pass since
      await app.deleteDay('2026-11-10');
      expect((await app.coordinator.ledger.entriesFor([b.key]))[b.key]?.tombstone, isNull);
      expect(part.existsSync(), isTrue);
    });

    test('a file that arrives during Delete Day and runs past midnight is kept and not deleted after', () async {
      final start = DateTime(2026, 11, 10, 23, 59).millisecondsSinceEpoch;
      final b = Bin(start)..frames(6000, p: speech);
      final app = AppPipeline.forTest();
      await app.start();
      await ChunkDownloader(app.coordinator.store).download(b.key, advertisedLength: b.length,
          transfer: (offset, path, overlap) async {
        await File(path).writeAsBytes(b.bytes);
        await app.deleteDay('2026-11-10'); // while the bytes are in the part, unsealed
        return StorageChunkResult(acceptedEnd: b.length, echoedAck: true);
      });
      await app.coordinator.store.setLifecycle(b.key, SourceLifecycle.complete, advertisedLength: b.length);
      expect((await app.coordinator.ledger.entriesFor([b.key]))[b.key]?.tombstone, isNull);
      await app.gate.release();
      expect((await app.coordinator.store.load(b.key)).length, b.length);
    });

    test('a copy an interrupted Reprocess all already put back is restored again', () async {
      final world = World(root);
      final a = Bin(1789100000000)..frames(300, p: speech);
      await world.arrive(a);
      final c = OwnershipCoordinator(root.path);
      await world.drain(c, boundaries: [a.force]);
      expect(await RawBinGate(c).release(), {a.key});
      final receipt = (await ledgerOf(root.path))[a.key]!.receipt!;
      // Adjustment Mode's copy, and the same copy already back on the phone, adopted.
      for (final under in ['adjustment_mode_segments', 'raw_segments']) {
        File('${root.path}/$under/${a.key.rel}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(a.bytes);
      }
      await world.store.adoptLegacy(a.key,
          lifecycle: receipt.lifecycle,
          advertisedLength: receipt.advertisedLength,
          firstSealedAtMs: receipt.firstSealedAtMs);
      final app = AppPipeline.forTest();
      await app.start();
      expect(await app.prepareReprocess(), {a.key});
    });
  });

  group('the Omi file list a pass finds ended sessions by', () {
    test('none without a complete list the sync took', () {
      expect(AppPipeline.listingOf(null, (link: 3, sessionId: 8)), isNull);
    });

    test('the session read on the link the list was taken on is the one it was taken in', () {
      expect(AppPipeline.listingOf((atMs: 5, link: 3), (link: 3, sessionId: 8)), (atMs: 5, liveSession: 8));
    });

    test('a session read on another link is not: the Omi may have restarted between', () {
      expect(AppPipeline.listingOf((atMs: 5, link: 3), (link: 2, sessionId: 8)), (atMs: 5, liveSession: null));
      expect(AppPipeline.listingOf((atMs: 5, link: 3), null), (atMs: 5, liveSession: null));
    });
  });
}
