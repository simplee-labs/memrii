import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/integration_coordinator.dart';
import 'package:omi/services/device_clock_anchor.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Documents extends PathProviderPlatform {
  _Documents(this.path);
  final String path;
  bool blockNext = false;
  int calls = 0;
  final entered = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<String?> getApplicationDocumentsPath() async {
    calls++;
    if (blockNext) {
      blockNext = false;
      entered.complete();
      await resume.future;
    }
    return path;
  }

  @override
  Future<String?> getTemporaryPath() async => path;
}

// Keep real filesystem operations while exposing Android-style paths on Windows,
// where Directory.list would otherwise give the production parser backslashes.
class _AndroidDirectory extends Fake implements Directory {
  _AndroidDirectory(this.inner, this.realZone);
  final Directory inner;
  final Zone realZone;

  FileSystemEntity _wrap(FileSystemEntity entity) {
    if (entity is Directory) return _AndroidDirectory(entity, realZone);
    if (entity is File) return realZone.run(() => File(entity.path.replaceAll('\\', '/')));
    return entity;
  }

  @override
  String get path => inner.path.replaceAll('\\', '/');
  @override
  Future<bool> exists() => inner.exists();
  @override
  bool existsSync() => inner.existsSync();
  @override
  Future<Directory> create({bool recursive = false}) async {
    await inner.create(recursive: recursive);
    return this;
  }

  @override
  void createSync({bool recursive = false}) => inner.createSync(recursive: recursive);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => inner.delete(recursive: recursive);
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      inner.list(recursive: recursive, followLinks: followLinks).map(_wrap);
  @override
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) =>
      inner.listSync(recursive: recursive, followLinks: followLinks).map(_wrap).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesUtil prefs;
  late Directory temp;
  late PathProviderPlatform oldPaths;
  late _Documents paths;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil();
    temp = Directory.systemTemp.createTempSync('memrii-retention-test-');
    oldPaths = PathProviderPlatform.instance;
    paths = _Documents(temp.path);
    PathProviderPlatform.instance = paths;
  });

  tearDown(() {
    PathProviderPlatform.instance = oldPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);
    temp.deleteSync(recursive: true);
  });

  Future<void> onAndroidPaths(Future<void> Function() action) {
    final realZone = Zone.current;
    return IOOverrides.runZoned(action,
        createDirectory: (path) => _AndroidDirectory(realZone.run(() => Directory(path)), realZone));
  }

  File recording(DateTime time, {String key = 'retention-test', bool unknown = false}) {
    final dir = Directory('${temp.path}/recordings/${RecordingsManager.fmtDate(time)}')..createSync(recursive: true);
    final prefix = unknown ? 'unknown' : 'recording';
    final audio = File('${dir.path}/${prefix}_${time.millisecondsSinceEpoch}.wav')
      ..writeAsBytesSync(List.filled(100, 7));
    final md = ByteData(417 + key.length + 4)
      ..setUint32(4, 120000, Endian.little)
      ..setUint32(408, 42, Endian.little)
      ..setUint32(412, 80, Endian.little);
    final bytes = md.buffer.asUint8List();
    bytes[416] = key.length;
    bytes.setRange(417, 417 + key.length, key.codeUnits);
    File(audio.path.replaceAll('.wav', '.meta')).writeAsBytesSync(bytes);
    return audio;
  }

  void anchor(DateTime now) {
    prefs.deviceClockAnchors = const DeviceClockAnchorSet.empty()
        .upsert(DeviceClockAnchor(sessionId: 42, deviceUptimeMs: 100000, wallClockMs: now.millisecondsSinceEpoch))
        .encode();
  }

  test('headless retention yields to clock correction requested during discovery and preserves delivery history',
      () async {
    final now = DateTime.now();
    final audio = recording(now.subtract(const Duration(days: 2)));
    await prefs.markUploadedToHeypocket('retention-test');
    prefs.keepRecordingsDays = 1;
    paths.blockNext = true;
    final coordinator = IntegrationCoordinator.application(prefs: prefs, isPipelineIdle: () => true);
    addTearDown(coordinator.dispose);

    await onAndroidPaths(() async {
      final refresh = coordinator.recordingsChanged();
      await paths.entered.future;
      anchor(now);
      final correcting = RecordingsManager.applyClockAnchors();
      expect(RecordingsManager.recordingsUnsettled, isTrue);
      expect(paths.calls, 1, reason: 'date correction waits until retention releases the filesystem');
      paths.resume.complete();
      await refresh;
      expect(audio.existsSync(), isTrue, reason: 'cleanup yielded before deleting the misdated audio');
      expect(await correcting, 1);
      await coordinator.recordingsChanged();
      final remaining = (await RecordingsManager().getBatches()).expand((b) => b.finalizedRecordings).toList();
      expect(remaining, hasLength(1));
      expect(remaining.single.startTime.millisecondsSinceEpoch, now.millisecondsSinceEpoch - 20000);
      expect(remaining.single.clockCorrected, isTrue);
      expect(prefs.isUploadedToHeypocket('retention-test'), isTrue);
      expect(RecordingsManager.recordingsUnsettled, isFalse);
    });
  });

  test('a known pending clock correction prevents retention even before the correction pass starts', () async {
    final now = DateTime.now();
    final audio = recording(now.subtract(const Duration(days: 2)));
    anchor(now);
    prefs.keepRecordingsDays = 1;
    await onAndroidPaths(() async {
      final batches = await RecordingsManager().getBatchesWithRetention();
      expect(audio.existsSync(), isTrue);
      expect(batches.expand((b) => b.finalizedRecordings), hasLength(1));
      expect(await RecordingsManager.applyClockAnchors(), 1);
    });
  });

  test('retention still deletes expired audio, metadata, upload sidecars, markers and delivery history', () async {
    final audio = recording(DateTime.now().subtract(const Duration(days: 2)), key: 'expired');
    final meta = File(audio.path.replaceAll('.wav', '.meta'));
    final sidecar = File(RecordingsManager.opusFrameSidecarPathFor(audio))..writeAsBytesSync([1, 2]);
    final marker = File('${audio.parent.path}/marker.edl')
      ..writeAsStringSync(jsonEncode({'segmentFilename': audio.uri.pathSegments.last}));
    final recent = recording(DateTime.now(), key: 'recent');
    final unknown = recording(DateTime.now().subtract(const Duration(days: 3)), key: 'unknown', unknown: true);
    await prefs.markUploadedToHeypocket('expired');
    prefs.keepRecordingsDays = 1;
    await onAndroidPaths(() async {
      await RecordingsManager().getBatchesWithRetention();
      expect(audio.existsSync(), isFalse);
      expect(meta.existsSync(), isFalse);
      expect(sidecar.existsSync(), isFalse);
      expect(marker.existsSync(), isFalse);
      expect(prefs.isUploadedToHeypocket('expired'), isFalse);
      expect(recent.existsSync(), isTrue);
      expect(unknown.existsSync(), isTrue);
    });
  });

  test('retention rechecks the current setting after an awaited directory lookup', () async {
    final audio = recording(DateTime.now().subtract(const Duration(days: 2)));
    prefs.keepRecordingsDays = 1;
    paths.blockNext = true;
    await onAndroidPaths(() async {
      final cleanup = RecordingsManager().getBatchesWithRetention();
      await paths.entered.future;
      prefs.keepRecordingsDays = 0;
      paths.resume.complete();
      await cleanup;
      expect(audio.existsSync(), isTrue);
      expect(RecordingsManager.recordingsUnsettled, isFalse);
    });
  });

  test('retention removes expired metadata for released audio without retaining it forever', () async {
    final audio = recording(DateTime.now().subtract(const Duration(days: 2)), key: 'released');
    final meta = File(audio.path.replaceAll('.wav', '.meta'));
    final bytes = meta.readAsBytesSync();
    bytes[417 + 'released'.length] = 1;
    meta.writeAsBytesSync(bytes);
    audio.deleteSync();
    await prefs.markUploadedToHeypocket('released');
    prefs.keepRecordingsDays = 1;
    await onAndroidPaths(() async {
      expect((await RecordingsManager().getBatches()).expand((b) => b.finalizedRecordings), hasLength(1));
      final remaining = await RecordingsManager().getBatchesWithRetention();
      expect(remaining.expand((b) => b.finalizedRecordings), isEmpty);
      expect(meta.existsSync(), isFalse);
      expect(prefs.isUploadedToHeypocket('released'), isFalse);
    });
  });
}
