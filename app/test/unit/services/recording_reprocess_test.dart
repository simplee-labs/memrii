import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../recordings_manager_test.dart' show MockPathProvider;
import 'recording_crop_test.dart' show pcmRecording;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;
  late RecordingsManager manager;
  final start = DateTime.utc(2026, 9, 30, 12);

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    SharedPreferencesUtil()
      ..manualMode = true
      ..vadEnabled = false
      ..audioSaveFormat = 'wav';
    docs = Directory.systemTemp.createTempSync('recording_reprocess');
    PathProviderPlatform.instance = MockPathProvider()..tempPath = docs.path;
    RecordingsManager.incompleteBinResolverForTest = () async => const {};
    RecordingsManager.heldBackBinResolverForTest = () async => const {};
    RecordingsManager.reprocessSyncInFlightForTest = () => false;
    manager = RecordingsManager();
  });

  tearDown(() {
    RecordingsManager.incompleteBinResolverForTest = null;
    RecordingsManager.heldBackBinResolverForTest = null;
    RecordingsManager.reprocessSyncInFlightForTest = null;
    RecordingsManager.forgetUploadsInFlightForTest();
    docs.deleteSync(recursive: true);
  });

  String relativeBin(DateTime time) => '${time.millisecondsSinceEpoch ~/ 1000}/'
      '${time.millisecondsSinceEpoch ~/ 1000}_42.bin';

  File writeBin(DateTime time, {String root = 'raw_segments', bool priority = true}) {
    final builder = BytesBuilder();
    final ms = time.millisecondsSinceEpoch;
    builder.add((ByteData(36)
          ..setUint32(0, 0xFFFFFFFB, Endian.little)
          ..setUint32(4, 28, Endian.little)
          ..setUint64(8, ms, Endian.little)
          ..setUint64(16, 100000, Endian.little)
          ..setUint32(28, 42, Endian.little))
        .buffer
        .asUint8List());
    if (priority) {
      builder.add((ByteData(20)
            ..setUint32(0, 0xFFFFFFF8, Endian.little)
            ..setUint64(4, ms, Endian.little)
            ..setUint32(12, 100000, Endian.little)
            ..setUint32(16, 42, Endian.little))
          .buffer
          .asUint8List());
    }
    for (var i = 0; i < 50; i++) {
      builder.add((ByteData(4)..setUint32(0, 4, Endian.little)).buffer.asUint8List());
      builder.add([0, 0, 0, 0]);
    }
    builder.add((ByteData(20)
          ..setUint32(0, 0xFFFFFFFC, Endian.little)
          ..setUint64(4, ms + 1000, Endian.little)
          ..setUint32(12, 101000, Endian.little)
          ..setUint32(16, 42, Endian.little))
        .buffer
        .asUint8List());
    final file = File(p.join(docs.path, root, relativeBin(time)));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(builder.toBytes());
    return file;
  }

  Conversation oldRecording({DateTime? time, bool draft = false, List<String> bins = const []}) {
    time ??= start;
    final folder = Directory(p.join(docs.path, 'recordings', time.toIso8601String().split('T').first))
      ..createSync(recursive: true);
    final suffix = draft ? '_draft' : '';
    final file = File(p.join(folder.path, 'recording_${time.millisecondsSinceEpoch}$suffix.wav'))
      ..writeAsBytesSync(pcmRecording());
    final key = 'old_${time.millisecondsSinceEpoch}$suffix'.codeUnits;
    final encodedBins = utf8.encode(jsonEncode(bins));
    final bytes = (ByteData(425 + key.length + encodedBins.length)
          ..setUint32(4, 10000, Endian.little)
          ..setUint32(408, 42, Endian.little)
          ..setUint32(412, 100, Endian.little)
          ..setUint32(421 + key.length, encodedBins.length, Endian.little))
        .buffer
        .asUint8List();
    bytes[416] = key.length;
    bytes.setRange(417, 417 + key.length, key);
    bytes.setRange(425 + key.length, bytes.length, encodedBins);
    File(p.setExtension(file.path, '.meta')).writeAsBytesSync(bytes);
    return Conversation.fromFile(file);
  }

  Future<List<Conversation>> recordings() async =>
      (await manager.getBatches()).expand((b) => b.finalizedRecordings).toList();

  test('an active sync prevents reset while source data is still changing', () async {
    final original = oldRecording();
    writeBin(start);
    RecordingsManager.reprocessSyncInFlightForTest = () => true;
    await expectLater(RecordingsManager.forceProcessAll(reprocessCovered: true), throwsStateError);
    expect(original.file.existsSync(), isTrue);
    expect(RecordingsManager.recordingsUnsettled, isFalse);
  });

  test('ordinary Force Process keeps existing recordings and crops', () async {
    final original = oldRecording(bins: [relativeBin(start)]);
    final copy = await manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5));
    writeBin(start);
    await RecordingsManager.forceProcessAll();
    expect(original.file.existsSync(), isTrue);
    expect(copy.file.existsSync(), isTrue);
    expect((await recordings()).map((c) => c.uploadKey).toSet(), {original.uploadKey, copy.uploadKey});
  });
}
