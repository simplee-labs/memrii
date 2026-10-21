import 'dart:io';
import 'dart:typed_data' show Endian;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/recordings/batch_card.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:omi/services/audio/recording_cropper.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../recordings_manager_test.dart' show MockPathProvider;

Uint8List pcmRecording({int seconds = 10, bool extraChunk = false}) {
  const sampleRate = 16000;
  final dataOffset = extraChunk ? 56 : 44;
  final data = ByteData(dataOffset + seconds * sampleRate * 2);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, 'WAVEfmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  if (extraChunk) {
    bytes.setRange(36, 40, 'JUNK'.codeUnits);
    data.setUint32(40, 4, Endian.little);
  }
  bytes.setRange(dataOffset - 8, dataOffset - 4, 'data'.codeUnits);
  data.setUint32(dataOffset - 4, seconds * sampleRate * 2, Endian.little);
  for (var sample = 0; sample < seconds * sampleRate; sample++) {
    data.setInt16(dataOffset + sample * 2, sample % 20000 - 10000, Endian.little);
  }
  return bytes;
}

void main() {
  late Directory docs;
  late Conversation source;
  late File sourceMeta;
  late Uint8List original;
  late RecordingsManager manager;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    docs = Directory.systemTemp.createTempSync('recording_crop');
    PathProviderPlatform.instance = MockPathProvider()..tempPath = docs.path;
    final folder = Directory(p.join(docs.path, 'recordings', '2026-10-11'))..createSync(recursive: true);
    final start = DateTime(2026, 10, 11, 12);
    original = pcmRecording();
    final audio = File(p.join(folder.path, 'recording_${start.millisecondsSinceEpoch}.wav'))
      ..writeAsBytesSync(original);
    final key = 'original-upload-key'.codeUnits;
    final metadata = (ByteData(421 + key.length)
          ..setUint32(4, 10000, Endian.little)
          ..setUint32(408, 42, Endian.little)
          ..setUint32(412, 100, Endian.little))
        .buffer
        .asUint8List();
    metadata[416] = key.length;
    metadata.setRange(417, 417 + key.length, key);
    metadata[420 + key.length] = 0x08 | 0x10;
    sourceMeta = File(p.setExtension(audio.path, '.meta'))..writeAsBytesSync(metadata);
    source = Conversation(
      file: audio,
      startTime: start,
      duration: const Duration(seconds: 10),
      uploadKey: 'original-upload-key',
      sessionId: 42,
      startUptime: 100,
      recordedManual: true,
      relativeBins: const ['session_42/recording.bin'],
    );
    manager = RecordingsManager();
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('me.memrii.app/audioCrop'), null);
    docs.deleteSync(recursive: true);
  });

  test('saving creates an exact playable crop in the library and preserves the original', () async {
    final originalMeta = sourceMeta.readAsBytesSync();
    final saved = await manager.saveCroppedConversation(source, const Duration(seconds: 2), const Duration(seconds: 5));
    final bytes = saved.file.readAsBytesSync();
    expect(bytes.sublist(44), orderedEquals(original.sublist(44 + 2 * 32000, 44 + 5 * 32000)));
    expect(ByteData.sublistView(bytes).getUint32(40, Endian.little), 3 * 32000);
    expect(saved.duration, const Duration(seconds: 3));
    expect(saved.startTime, source.startTime.add(const Duration(seconds: 2)));
    expect(saved.isCropped, isTrue);
    expect(Conversation.fromFile(saved.file).isCropped, isTrue);
    expect(saved.uploadKey, isNot(source.uploadKey));
    expect(saved.relativeBins, isEmpty);
    expect(saved.recordedManual, isTrue);
    expect(source.file.readAsBytesSync(), orderedEquals(original));
    expect(sourceMeta.readAsBytesSync(), orderedEquals(originalMeta));
    final meta = File(p.setExtension(saved.file.path, '.meta')).readAsBytesSync();
    expect(meta.sublist(8, 408).any((b) => b != 0), isTrue, reason: 'the crop has its own waveform');
    expect(RecordingsManager.metaMarksHardStart(meta), isTrue);
    expect(RecordingsManager.metaMarksHardEnd(meta), isTrue);
    final batches = await manager.getBatches();
    expect(batches.single.finalizedRecordings, hasLength(2));
    expect(batches.single.finalizedRecordings.where((c) => c.isCropped), hasLength(1));
    final markers = await manager.getMarkerConversations();
    expect(markers, hasLength(1));
    expect(markers.single.userSaved, isTrue);
    expect(markers.single.isHighPriority, isTrue, reason: 'a crop of an ordinary recording is priority too');
    expect(p.equals(markers.single.segment!.path, saved.file.path), isTrue);
  });

  test('short cropped copies remain in Main and Markers views', () async {
    final saved = await manager.saveCroppedConversation(source, const Duration(seconds: 1), const Duration(seconds: 3));
    final batch = (await manager.getBatches()).single;
    final markers = await manager.getMarkerConversations();
    final markerMap = {p.basename(saved.file.path): markers};
    final main = filterBatchRows(batch, RecordingFilterMode.visible, 60);
    expect(main.recordings.map((c) => p.basename(c.file.path)), [p.basename(saved.file.path)]);
    final marked = filterBatchRows(batch, RecordingFilterMode.visible, 60, markersOnly: true, markerMap: markerMap);
    expect(marked.recordings, hasLength(1));
    final hidden = filterBatchRows(batch, RecordingFilterMode.hidden, 60);
    expect(hidden.recordings.any((c) => c.isCropped), isFalse);
  });

  test('full and repeated crops have separate files and identities', () async {
    final first = await manager.saveCroppedConversation(source, Duration.zero, source.duration);
    final second = await manager.saveCroppedConversation(source, Duration.zero, source.duration);
    expect(first.file.path, isNot(source.file.path));
    expect(second.file.path, isNot(first.file.path));
    expect(second.uploadKey, isNot(first.uploadKey));
    expect(await manager.getMarkerConversations(), hasLength(2));
    expect(source.file.readAsBytesSync(), orderedEquals(original));
  });

  test('cropped copies are priority and can be toggled independently', () async {
    final saved = await manager.saveCroppedConversation(source, const Duration(seconds: 2), const Duration(seconds: 5));
    final markers = await manager.getMarkerConversations();
    expect(markers.single.isHighPriority, isTrue);
    await manager.setConversationPriority(saved, false);
    expect(await manager.getMarkerConversations(), isEmpty);
    expect(saved.file.existsSync(), isTrue);
    expect(source.file.readAsBytesSync(), orderedEquals(original));
  });

  test('invalid ranges and unreadable audio do not publish a partial recording', () async {
    for (final range in [
      (const Duration(seconds: -1), const Duration(seconds: 2)),
      (const Duration(seconds: 2), const Duration(seconds: 2)),
      (const Duration(seconds: 2), const Duration(seconds: 12)),
    ]) {
      await expectLater(manager.saveCroppedConversation(source, range.$1, range.$2), throwsArgumentError);
    }
    source.file.writeAsBytesSync([1, 2, 3]);
    await expectLater(manager.saveCroppedConversation(source, const Duration(seconds: 1), const Duration(seconds: 2)),
        throwsFormatException);
    expect(await manager.getMarkerConversations(), isEmpty);
    final files = source.file.parent.listSync().whereType<File>().map((f) => p.basename(f.path)).toSet();
    expect(files, {p.basename(source.file.path), p.basename(sourceMeta.path)});
  });

  test('WAV cropping handles extra RIFF chunks rather than assuming audio starts at byte 44', () async {
    final audio = File(p.join(docs.path, 'extra.wav'))..writeAsBytesSync(pcmRecording(extraChunk: true));
    final target = File(p.join(docs.path, 'cropped.wav'));
    final result = await RecordingCropper.crop(audio, target, const Duration(seconds: 2), const Duration(seconds: 5));
    expect(result.duration, const Duration(seconds: 3));
    expect(target.readAsBytesSync().sublist(44),
        orderedEquals(audio.readAsBytesSync().sublist(56 + 2 * 32000, 56 + 5 * 32000)));
  });

  for (final succeeds in [true, false]) {
    test('compressed crops use accurate decoding and publish only on success (success=$succeeds)', () async {
      Map<Object?, Object?>? arguments;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('me.memrii.app/audioCrop'), (call) async {
        expect(call.method, 'crop');
        arguments = Map<Object?, Object?>.from(call.arguments as Map);
        await File(arguments!['outputPath'] as String).writeAsBytes(pcmRecording(seconds: 3, extraChunk: true));
        if (!succeeds) throw PlatformException(code: 'AUDIO_CROP_ERROR', message: 'Synthetic decode failure');
        return null;
      });
      final compressed = File(p.join(source.file.parent.path, 'input with spaces.m4a'))..writeAsBytesSync([1]);
      final input = Conversation(file: compressed, startTime: source.startTime, duration: source.duration);
      final save = manager.saveCroppedConversation(input, const Duration(seconds: 2), const Duration(seconds: 5));
      if (succeeds) {
        final cropped = await save;
        expect(cropped.duration, const Duration(seconds: 3));
        expect(cropped.isCropped, isTrue);
        expect(cropped.file.lengthSync(), greaterThan(3 * 32000));
      } else {
        await expectLater(save, throwsA(isA<FileSystemException>()));
        expect(await manager.getMarkerConversations(), isEmpty);
        expect(source.file.parent.listSync().any((f) => f.path.endsWith('.tmp')), isFalse);
      }
      expect(arguments!['sourcePath'], compressed.path);
      expect(arguments!['startUs'], 2000000);
      expect(arguments!['endUs'], 5000000);
      expect(arguments!['outputPath'], endsWith('.tmp'));
    });
  }

  test('crop duration comes from actual audio even when legacy metadata is only an estimate', () async {
    final estimated =
        Conversation(file: source.file, startTime: source.startTime, duration: const Duration(seconds: 1));
    final saved =
        await manager.saveCroppedConversation(estimated, const Duration(seconds: 2), const Duration(seconds: 5));
    expect(saved.duration, const Duration(seconds: 3));
  });

  test('a cropped copy never claims nearby raw bins as already processed', () async {
    await manager.saveCroppedConversation(source, const Duration(seconds: 2), const Duration(seconds: 5));
    source.file.deleteSync();
    sourceMeta.deleteSync();
    final raw = Directory(p.join(docs.path, 'raw_segments', 'session_42'))..createSync(recursive: true);
    final ts = source.startTime.subtract(const Duration(seconds: 30)).millisecondsSinceEpoch ~/ 1000;
    final bin = File(p.join(raw.path, '${ts}_42.bin'))..writeAsBytesSync(Uint8List(36 + 200));
    expect(await RecordingsManager.coveredBinPaths([bin]), isEmpty);
  });
}
