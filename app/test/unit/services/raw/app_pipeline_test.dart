import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/device_clock_anchor.dart';
import 'package:omi/services/raw/app_pipeline.dart';
import 'package:omi/services/raw/chunk_download.dart';
import 'package:omi/services/raw/coordinator.dart';
import 'package:omi/services/raw/gate.dart';
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

    test('Delete Day after a Stop leaves a file on its first transfer alone', () async {
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

    test('a file that arrives during Delete Day is left alone', () async {
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
      expect(AppPipeline.listingOf((atMs: 5, link: 3, linkSinceMs: 1), (link: 3, sessionId: 8)),
          (atMs: 5, liveSession: 8));
    });

    test('a session read on another link is not: the Omi may have restarted between', () {
      expect(AppPipeline.listingOf((atMs: 5, link: 3, linkSinceMs: 1), (link: 2, sessionId: 8)),
          (atMs: 5, liveSession: null));
      expect(AppPipeline.listingOf((atMs: 5, link: 3, linkSinceMs: 1), null), (atMs: 5, liveSession: null));
    });
  });

  group('the quiet mark', () {
    const linkUp = 1794392565000;
    const listed = (atMs: linkUp + 9000, link: 4, linkSinceMs: linkUp);

    test('none without a complete list the sync took, nor for a link with no start', () {
      expect(AppPipeline.quietOf(null, const []).$1, isNull);
      expect(AppPipeline.quietOf((atMs: 5, link: 4, linkSinceMs: 0), const []).$1, isNull);
    });

    test('is three minutes before the link the list was taken on came up, not when the list was taken', () {
      final (q, why) = AppPipeline.quietOf(listed, const []);
      expect(q!.atMs, linkUp - 3 * 60 * 1000);
      expect(why, contains('link 4'));
      expect(q.uptimeAt, isEmpty, reason: 'no anchor: nothing to measure a silence by');
      expect(AppPipeline.connectQuietMarginMs, 3 * 60 * 1000,
          reason: 'two minutes the Omi may leave a young file open, and one for the phone to see the link');
    });

    test("each session's uptime then comes from its newest clock anchor", () {
      final anchors = [
        const DeviceClockAnchor(sessionId: 8, deviceUptimeMs: 1000000, wallClockMs: linkUp - 600000),
        const DeviceClockAnchor(sessionId: 9, deviceUptimeMs: 50000, wallClockMs: linkUp - 3600000),
        // The newest of session 8: it wins.
        const DeviceClockAnchor(sessionId: 8, deviceUptimeMs: 2000000, wallClockMs: linkUp + 5000),
      ];
      final q = AppPipeline.quietOf(listed, anchors).$1!;
      expect(q.uptimeAt[8], 2000000 - 5000 - 3 * 60 * 1000);
      expect(q.uptimeAt[9], 50000 + 3600000 - 3 * 60 * 1000);
      expect(q.uptimeAt.keys, unorderedEquals([8, 9]));
    });

    test('an uptime past the 32-bit wrap, or before the session began, stays in 32 bits', () {
      final q = AppPipeline.quietOf(listed, [
        const DeviceClockAnchor(sessionId: 8, deviceUptimeMs: 10000, wallClockMs: linkUp),
      ]).$1!;
      expect(q.uptimeAt[8], (10000 - 3 * 60 * 1000) & 0xFFFFFFFF,
          reason: 'the Omi had not started three minutes before: the planner reads it as after the audio');
    });
  });
}
