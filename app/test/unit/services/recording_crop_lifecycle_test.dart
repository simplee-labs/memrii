import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_api_client.dart';
import 'package:omi/integrations/connectors/omi_cloud/omi_cloud_connector.dart';
import 'package:omi/integrations/integration_recording.dart';
import 'package:omi/models/recordings/recording_filename.dart';
import 'package:omi/services/audio/recording_cropper.dart';
import 'package:omi/services/device_clock_anchor.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../recordings_manager_test.dart' show MockPathProvider;
import 'recording_crop_test.dart' show pcmRecording;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory docs;
  late RecordingsManager manager;

  setUp(() async {
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    docs = Directory.systemTemp.createTempSync('crop_lifecycle');
    PathProviderPlatform.instance = MockPathProvider()..tempPath = docs.path;
    manager = RecordingsManager();
  });

  tearDown(() {
    RecordingCropper.opusLibraryPathForTest = null;
    messenger.setMockMethodCallHandler(const MethodChannel('me.memrii.app/audioCrop'), null);
    docs.deleteSync(recursive: true);
  });

  String dateFolder(DateTime start) => '${start.year.toString().padLeft(4, '0')}-'
      '${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';

  Conversation source({DateTime? start, bool unknown = false, int uptime = 100}) {
    start ??= DateTime(2026, 9, 30, 12);
    final folder = Directory(p.join(docs.path, 'recordings', dateFolder(start)))..createSync(recursive: true);
    final file = File(p.join(folder.path, '${unknown ? 'unknown' : 'recording'}_${start.millisecondsSinceEpoch}.wav'))
      ..writeAsBytesSync(pcmRecording());
    final key = 'source_${start.millisecondsSinceEpoch}'.codeUnits;
    final metadata = ByteData(421 + key.length)
      ..setUint32(4, 10000, Endian.little)
      ..setUint32(408, 42, Endian.little)
      ..setUint32(412, uptime, Endian.little);
    final bytes = metadata.buffer.asUint8List();
    bytes[416] = key.length;
    bytes.setRange(417, 417 + key.length, key);
    File(p.setExtension(file.path, '.meta')).writeAsBytesSync(bytes);
    return Conversation.fromFile(file);
  }

  Future<Map<String, Conversation>> library() async => {
        for (final batch in await manager.getBatches())
          for (final conversation in batch.finalizedRecordings) conversation.uploadKey!: conversation,
      };

  void anchor(DateTime correctStart) {
    SharedPreferencesUtil().deviceClockAnchors = const DeviceClockAnchorSet.empty()
        .upsert(
            DeviceClockAnchor(sessionId: 42, deviceUptimeMs: 100000, wallClockMs: correctStart.millisecondsSinceEpoch))
        .encode();
  }

  test('priority updates from an old player entry resolve the corrected recording identity', () async {
    final original = source(start: DateTime(2026, 9, 28, 12));
    anchor(DateTime(2026, 9, 30, 12));
    await RecordingsManager.applyClockAnchors();
    final moved = (await library())[original.uploadKey]!;
    expect(original.file.existsSync(), isFalse);

    await manager.setConversationPriority(original, true);
    final marker = (await manager.getMarkerConversations()).single;
    expect(marker.isHighPriority, isTrue);
    expect(marker.isPending, isFalse);
    expect(p.equals(marker.segment!.path, moved.file.path), isTrue);
    expect(marker.markerTime, moved.startTime);
    await manager.setConversationPriority(original, false);
    expect(await manager.getMarkerConversations(), isEmpty);
    await manager.setConversationPriority(original, true);
    expect((await manager.getMarkerConversations()).single.edlFile.path, marker.edlFile.path);
  });

  test('priority cannot create an orphan or target a replacement after deletion', () async {
    final original = source();
    original.file.deleteSync();
    await expectLater(manager.setConversationPriority(original, true), throwsA(isA<FileSystemException>()));
    expect(await manager.getMarkerConversations(), isEmpty);

    final replacement = source(start: original.startTime.add(const Duration(days: 1)));
    replacement.file.copySync(original.file.path);
    File(p.setExtension(replacement.file.path, '.meta')).copySync(p.setExtension(original.file.path, '.meta'));
    await expectLater(manager.setConversationPriority(original, true), throwsA(isA<FileSystemException>()));
    expect(await manager.getMarkerConversations(), isEmpty);
  });

  test('an open crop follows a corrected source identity and timestamp', () async {
    final original = source(start: DateTime(2026, 9, 28, 12));
    final originalBytes = original.file.readAsBytesSync();
    final corrected = DateTime(2026, 9, 30, 12);
    anchor(corrected);
    await RecordingsManager.applyClockAnchors();
    expect(original.file.existsSync(), isFalse);

    final crop =
        await manager.saveCroppedConversation(original, const Duration(milliseconds: 2125), const Duration(seconds: 5));
    expect(crop.startTime, corrected.add(const Duration(milliseconds: 2125)));
    expect(crop.startUptimeMs, 102125);
    expect(crop.clockCorrected, isTrue);
    expect(crop.file.readAsBytesSync().sublist(44), originalBytes.sublist(44 + 2125 * 32, 44 + 5000 * 32));
    expect((await manager.getMarkerConversations()).single.isPending, isFalse);
  });

  test('a crop queued behind a date assignment resolves its source after the move', () async {
    final original = source(unknown: true);
    final assigned = DateTime(2026, 10, 1, 12);
    final move = RecordingsManager.promoteSessionToDate(original, assigned);
    final save = manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5));
    await move;
    final crop = await save;
    expect(crop.startTime, assigned.add(const Duration(seconds: 2)));
    expect(crop.isUnknown, isFalse);
    expect(crop.file.existsSync(), isTrue);
  });

  test('a deleted crop source cannot be replaced by different audio at the same path', () async {
    final original = source();
    original.file.deleteSync();
    await expectLater(manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5)),
        throwsA(isA<FileSystemException>()));
    final replacement = source(start: original.startTime.add(const Duration(days: 1)));
    replacement.file.copySync(original.file.path);
    File(p.setExtension(replacement.file.path, '.meta')).copySync(p.setExtension(original.file.path, '.meta'));
    await expectLater(manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5)),
        throwsA(isA<FileSystemException>()));
    expect(await manager.getMarkerConversations(), isEmpty);
  });

  for (final stage in ['audio', 'opus', 'metadata', 'marker', 'markerOnly']) {
    test('startup removes an interrupted crop at the $stage stage', () async {
      final original = source();
      final originalBytes = original.file.readAsBytesSync();
      final originalMeta = File(p.setExtension(original.file.path, '.meta')).readAsBytesSync();
      final copy =
          await manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5));
      final marker = (await manager.getMarkerConversations()).single;
      final meta = File(p.setExtension(copy.file.path, '.meta'));
      final opus = File(RecordingsManager.opusFrameSidecarPathFor(copy.file))..writeAsBytesSync([1, 2, 3]);
      copy.file.renameSync('${copy.file.path}.tmp');
      if (stage != 'marker' && stage != 'markerOnly') marker.edlFile.deleteSync();
      if (stage == 'audio' || stage == 'opus') meta.renameSync('${meta.path}.tmp');
      if (stage == 'audio') opus.renameSync('${opus.path}.tmp');
      if (stage == 'metadata') {
        File('${marker.edlFile.path}.tmp').writeAsStringSync('{');
      }
      if (stage == 'markerOnly') {
        File('${copy.file.path}.tmp').deleteSync();
        meta.deleteSync();
        opus.deleteSync();
      }
      await RecordingsManager.cleanupOrphanedTempFiles();
      await RecordingsManager.cleanupOrphanedTempFiles();

      expect(original.file.readAsBytesSync(), originalBytes);
      expect(File(p.setExtension(original.file.path, '.meta')).readAsBytesSync(), originalMeta);
      expect(original.file.parent.listSync().whereType<File>(), hasLength(2));
      expect(await library(), hasLength(1));
      expect(await manager.getMarkerConversations(), isEmpty);
    });
  }

  test('startup removes a crop sidecar published before any metadata or marker', () async {
    final original = source();
    final audio = File(p.join(original.file.parent.path, 'unknown_100000_crop_interrupted.wav'));
    final sidecar = File(RecordingsManager.opusFrameSidecarPathFor(audio))..writeAsBytesSync([1, 2, 3]);
    await RecordingsManager.cleanupOrphanedTempFiles();
    expect(sidecar.existsSync(), isFalse);
    expect(original.file.parent.listSync().whereType<File>(), hasLength(2));
  });

  test('startup removes legacy crop leftovers and markers in other date folders', () async {
    final original = source();
    final copy =
        await manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5));
    final marker = (await manager.getMarkerConversations()).single;
    final legacy = File(p.join(copy.file.parent.path, 'recording_${copy.startTime.millisecondsSinceEpoch}.wav'));
    copy.file.renameSync('${legacy.path}.tmp');
    File(p.setExtension(copy.file.path, '.meta')).renameSync(p.setExtension(legacy.path, '.meta'));
    final later = Directory(p.join(docs.path, 'recordings', '2026-10-01'))..createSync(recursive: true);
    final data = jsonDecode(marker.edlFile.readAsStringSync()) as Map<String, dynamic>;
    data['segmentFilename'] = p.basename(legacy.path);
    marker.edlFile.deleteSync();
    final crossFolderMarker = File(p.join(later.path, p.basename(marker.edlFile.path)))
      ..writeAsStringSync(jsonEncode(data));
    await RecordingsManager.cleanupOrphanedTempFiles();
    expect(crossFolderMarker.existsSync(), isFalse);
    expect(original.file.parent.listSync().whereType<File>(), hasLength(2));
  });

  test('startup preserves completed known, unknown and passthrough crops and unrelated markers', () async {
    final original = source();
    final unknown = source(start: DateTime.fromMillisecondsSinceEpoch(100000), unknown: true);
    final copies = [
      await manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5)),
      await manager.saveCroppedConversation(unknown, Duration.zero, const Duration(seconds: 5)),
    ];
    for (final copy in copies) {
      File(RecordingsManager.opusFrameSidecarPathFor(copy.file)).writeAsBytesSync([1, 2, 3]);
      File('${copy.file.path}.tmp').writeAsBytesSync([1]);
    }
    final released =
        await manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5));
    final meta = File(p.setExtension(released.file.path, '.meta'));
    final bytes = meta.readAsBytesSync();
    bytes[417 + bytes[416]] |= 0x01;
    meta.writeAsBytesSync(bytes);
    released.file.deleteSync();
    File(RecordingsManager.opusFrameSidecarPathFor(released.file)).writeAsBytesSync([4, 5]);
    await manager.writeMarkerEdlTest(docs.path, {
      'filename': 'recording_1234567890000.wav',
      'markerMs': 1234567890000,
      'offsetMs': 0,
      'durationMs': 0,
    });
    final markersBefore = (await manager.getMarkerConversations()).map((m) => m.edlFile.path).toSet();
    await RecordingsManager.cleanupOrphanedTempFiles();
    for (final copy in copies) {
      expect(copy.file.existsSync(), isTrue);
      expect(File(RecordingsManager.opusFrameSidecarPathFor(copy.file)).existsSync(), isTrue);
      expect(File('${copy.file.path}.tmp').existsSync(), isFalse);
    }
    expect(meta.existsSync(), isTrue);
    expect(File(RecordingsManager.opusFrameSidecarPathFor(released.file)).existsSync(), isTrue);
    expect((await library())[released.uploadKey]!.passthrough, isTrue);
    expect((await manager.getMarkerConversations()).map((m) => m.edlFile.path).toSet(), markersBefore);
  });

  test('concurrent copies have stable distinct filenames without changing their start time', () async {
    final original = source();
    final copies = await Future.wait(
        List.generate(3, (_) => manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5))));
    expect(copies.map((c) => c.file.path).toSet(), hasLength(3));
    expect(copies.map((c) => c.uploadKey).toSet(), hasLength(3));
    for (final copy in copies) {
      expect(copy.startTime, original.startTime);
      expect(RecordingFilename.cropSuffix(copy.file.path), '_${copy.uploadKey}');
    }
    expect(await library(), hasLength(4));
    expect(await manager.getMarkerConversations(), hasLength(3));
  });

  test('unknown originals and repeated zero-start copies all receive an assigned date', () async {
    final original = source(start: DateTime.fromMillisecondsSinceEpoch(100000), unknown: true);
    final first = await manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5));
    final second = await manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5));
    final picked = DateTime(2026, 9, 30, 12);
    await RecordingsManager.promoteSessionToDate(original, picked, include: (c) => c.isUnknown);
    final recordings = await library();
    for (final old in [original, first, second]) {
      final moved = recordings[old.uploadKey]!;
      expect(moved.startTime, picked);
      expect(moved.isUnknown, isFalse);
      expect(moved.file.existsSync(), isTrue);
      expect(RecordingFilename.cropSuffix(moved.file.path), RecordingFilename.cropSuffix(old.file.path));
    }
    final markers = await manager.getMarkerConversations();
    expect(markers, hasLength(2));
    expect(markers.every((m) => !m.isPending && m.isHighPriority), isTrue);
    expect(markers.map((m) => m.markerTime.millisecondsSinceEpoch).toSet(), hasLength(2));
  });

  test('correction and undo retain copy identities and fractional offsets, including nested crops', () async {
    final original = source(start: DateTime(2026, 9, 28, 12));
    final full = await manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5));
    final partial =
        await manager.saveCroppedConversation(original, const Duration(milliseconds: 2125), const Duration(seconds: 5));
    final nested =
        await manager.saveCroppedConversation(partial, const Duration(milliseconds: 250), const Duration(seconds: 1));
    expect(partial.startUptimeMs, 102125);
    expect(nested.startUptimeMs, 102375);
    final correct = DateTime(2026, 9, 30, 12);
    anchor(correct);
    expect(await RecordingsManager.applyClockAnchors(), 1);
    expect(await RecordingsManager.applyClockAnchors(), 0);
    var recordings = await library();
    final offsets = {original.uploadKey: 0, full.uploadKey: 0, partial.uploadKey: 2125, nested.uploadKey: 2375};
    for (final entry in offsets.entries) {
      final moved = recordings[entry.key]!;
      expect(moved.startTime, correct.add(Duration(milliseconds: entry.value)));
      expect(moved.clockCorrected, isTrue);
    }
    expect((await manager.getMarkerConversations()).every((m) => !m.isPending), isTrue);
    await RecordingsManager.revertClockCorrection(recordings[nested.uploadKey]!);
    recordings = await library();
    for (final entry in offsets.entries) {
      final restored = recordings[entry.key]!;
      expect(restored.startTime, original.startTime.add(Duration(milliseconds: entry.value)));
      expect(restored.clockCorrected, isFalse);
    }
    expect(await manager.getMarkerConversations(), hasLength(3));
  });

  test('zero or absent source uptime stays unknown after cropping', () async {
    final original = source(uptime: 0);
    final absent =
        Conversation(file: original.file, startTime: original.startTime, duration: original.duration, sessionId: 42);
    for (final input in [original, absent]) {
      final copy = await manager.saveCroppedConversation(input, const Duration(seconds: 2), const Duration(seconds: 5));
      expect(copy.startUptime, 0);
      expect(copy.startUptimeMs, isNull);
      anchor(original.startTime);
      expect(await RecordingsManager.applyClockAnchors(), 0);
      expect(copy.file.existsSync(), isTrue);
      expect(copy.startTime, original.startTime.add(const Duration(seconds: 2)));
    }
  });

  test('passthrough metadata still parses the copy timestamp and fractional uptime', () async {
    final original = source();
    final copy =
        await manager.saveCroppedConversation(original, const Duration(milliseconds: 2125), const Duration(seconds: 5));
    final meta = File(p.setExtension(copy.file.path, '.meta'));
    final bytes = meta.readAsBytesSync();
    bytes[417 + bytes[416]] |= 0x01;
    meta.writeAsBytesSync(bytes);
    copy.file.deleteSync();
    final released = await Conversation.fromMetaOnly(meta);
    expect(released!.startTime, copy.startTime);
    expect(released.startUptimeMs, 102125);
    expect(released.uploadKey, copy.uploadKey);
    expect(released.isCropped, isTrue);
    expect((await manager.getBatches()).single.finalizedRecordings.singleWhere((c) => c.isCropped).startTime,
        copy.startTime);
  });

  test('older copies without filename suffixes get distinct slots during correction', () async {
    final original = source(start: DateTime(2026, 9, 28, 12));
    final copy = await manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5));
    final legacy = File(p.join(copy.file.parent.path, 'recording_${copy.startTime.millisecondsSinceEpoch + 1}.wav'));
    await copy.file.rename(legacy.path);
    await File(p.setExtension(copy.file.path, '.meta')).rename(p.setExtension(legacy.path, '.meta'));
    final marker = (await manager.getMarkerConversations()).single;
    final data = jsonDecode(marker.edlFile.readAsStringSync()) as Map<String, dynamic>;
    data['segmentFilename'] = p.basename(legacy.path);
    await RecordingsManager.writeJsonAtomic(marker.edlFile, data);
    anchor(DateTime(2026, 9, 30, 12));
    await RecordingsManager.applyClockAnchors();
    final moved = (await library())[copy.uploadKey]!;
    expect(moved.startTime, DateTime(2026, 9, 30, 12));
    expect(RecordingFilename.cropSuffix(moved.file.path), '_${copy.uploadKey}');
    expect((await manager.getMarkerConversations()).single.isPending, isFalse);
  });

  test('saved copies do not become hard boundaries for unrelated late drafts', () async {
    final original = source();
    final copy =
        await manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5));
    final draftStart = original.startTime.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch;
    final draft = File(p.join(original.file.parent.path, 'recording_${draftStart}_draft.wav'))
      ..writeAsBytesSync(pcmRecording(seconds: 2));
    File(p.setExtension(draft.path, '.meta'))
        .writeAsBytesSync((ByteData(8)..setUint32(4, 2000, Endian.little)).buffer.asUint8List());
    await manager.stitchDraftRecordingsForTest();
    expect(draft.existsSync(), isTrue, reason: 'the crop is an edit, not a device boundary');
    expect(copy.file.existsSync(), isTrue);
  });

  test('priority removal resolves cross-folder draft aliases and reuses hidden markers', () async {
    final original = source();
    final later = Directory(p.join(docs.path, 'recordings', '2026-10-01'))..createSync(recursive: true);
    final markerMs = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    final edl = File(p.join(later.path, 'marker_$markerMs.edl'))
      ..writeAsStringSync(jsonEncode({
        'markerTimestampMs': markerMs,
        'segmentFilename': 'recording_later.wav',
        'markerOffsetMs': 0,
        'cropStartMs': 100,
        'cropEndMs': 900,
        'userSaved': true,
        'isHighPriority': true,
      }));
    await manager.reanchorMarkerEdlsTest(
        fromFilename: 'recording_later.wav',
        toFilename: p.basename(original.file.path).replaceFirst('.wav', '_draft.wav'),
        offsetShiftMs: 1000,
        newDurationMs: 10000,
        folders: [original.file.parent, later]);
    expect((await manager.getMarkerConversations()).single.isHighPriority, isTrue);
    await manager.setConversationPriority(original, false);
    expect(await manager.getMarkerConversations(), isEmpty);
    final hidden = jsonDecode(edl.readAsStringSync()) as Map;
    expect(hidden['priorityOverride'], isFalse);
    expect(hidden['cropStartMs'], 1100);
    expect(hidden['cropEndMs'], 1900);
    await manager.setConversationPriority(original, true);
    expect((await manager.getMarkerConversations()).single.isHighPriority, isTrue);
    expect(later.listSync().whereType<File>().where((f) => f.path.endsWith('.edl')), hasLength(1));
  });

  test('a later failed overlapping save cannot remove the successful copy', () async {
    final original = source();
    final compressed = File(p.setExtension(original.file.path, '.m4a'))..writeAsBytesSync([1]);
    final input = Conversation(file: compressed, startTime: original.startTime, duration: original.duration);
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    final arguments = <int, Map<Object?, Object?>>{};
    var sessionId = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('me.memrii.app/audioCrop'), (call) async {
      expect(call.method, 'crop');
      final id = ++sessionId;
      arguments[id] = Map<Object?, Object?>.from(call.arguments as Map);
      if (id == 1) {
        firstStarted.complete();
        await finishFirst.future;
      }
      await File(arguments[id]!['outputPath'] as String).writeAsBytes(pcmRecording(seconds: 3));
      if (id != 1) throw PlatformException(code: 'AUDIO_CROP_ERROR', message: 'Synthetic decode failure');
      return null;
    });
    final firstSave = manager.saveCroppedConversation(input, const Duration(seconds: 2), const Duration(seconds: 5));
    final secondSave = manager.saveCroppedConversation(input, const Duration(seconds: 2), const Duration(seconds: 5));
    final secondFailure = expectLater(secondSave, throwsA(isA<FileSystemException>()));
    await firstStarted.future;
    final cleanup = RecordingsManager.cleanupOrphanedTempFiles();
    expect(arguments, hasLength(1), reason: 'overlapping saves are serialized');
    expect(RecordingsManager.recordingsUnsettled, isTrue);
    finishFirst.complete();
    final copy = await firstSave;
    await secondFailure;
    await cleanup;
    expect(arguments[1]!['outputPath'], isNot(arguments[2]!['outputPath']));
    expect(copy.file.existsSync(), isTrue);
    expect(Conversation.fromFile(copy.file).uploadKey, copy.uploadKey);
    expect(await manager.getMarkerConversations(), hasLength(1));
    expect(RecordingsManager.recordingsUnsettled, isFalse);
    expect(copy.file.parent.listSync().any((f) => f.path.endsWith('.tmp')), isFalse);
  });

  test('sidecar frames contain only the crop, then zero padding and codec flush', () async {
    final original = source();
    final cropped = File(p.join(docs.path, 'selected.wav'));
    await RecordingCropper.crop(original.file, cropped, const Duration(seconds: 2), const Duration(milliseconds: 2125));
    final frames = <Int16List>[];
    final output = File(p.join(docs.path, 'frames.bin'));
    RecordingCropper.writeOpusFramesWithEncoderForTest(cropped, output, (frame) {
      frames.add(Int16List.fromList(frame));
      return Uint8List.fromList([1, 2, 3]);
    });
    final selected = ByteData.sublistView(cropped.readAsBytesSync(), 44);
    final samples = [for (var i = 0; i < selected.lengthInBytes; i += 2) selected.getInt16(i, Endian.little)];
    final flattened = frames.expand((frame) => frame).toList();
    expect(flattened.take(samples.length), orderedEquals(samples));
    expect(flattened.skip(samples.length).every((sample) => sample == 0), isTrue);
    expect(frames, hasLength(8));
    final bytes = output.readAsBytesSync();
    for (var offset = 0; offset < bytes.length; offset += 7) {
      expect(ByteData.sublistView(bytes).getUint32(offset, Endian.little), 3);
      expect(bytes.sublist(offset + 4, offset + 7), [1, 2, 3]);
    }
  });

  test('sidecar encoding failures leave the original and no partial copy', () async {
    final original = source();
    SharedPreferencesUtil().omiEnabled = true;
    RecordingCropper.opusLibraryPathForTest = p.join(docs.path, 'missing-opus-library');
    await expectLater(manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5)),
        throwsA(anything));
    expect(original.file.existsSync(), isTrue);
    expect(await library(), hasLength(1));
    expect(await manager.getMarkerConversations(), isEmpty);
    expect(original.file.parent.listSync().whereType<File>(), hasLength(2));
  });

  test('native Opus crops can upload and keep their sidecar and delivery history through date changes', () async {
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config = jsonDecode(await configFile.readAsString()) as Map;
    final package =
        (config['packages'] as List).cast<Map>().singleWhere((entry) => entry['name'] == 'opus_flutter_windows');
    final packageRoot = configFile.uri.resolve(package['rootUri'] as String).toFilePath();
    final libraryPath = p.join(
        packageRoot, 'assets', Platform.version.contains('x64') ? 'libopus_x64.dll.blob' : 'libopus_x86.dll.blob');
    RecordingCropper.opusLibraryPathForTest = libraryPath;
    final original = source(start: DateTime(2026, 9, 28, 12));
    final prefs = SharedPreferencesUtil()..omiEnabled = true;
    await prefs.setOmiCredentials(refreshToken: 'test-refresh', apiKey: 'test-key');
    final copy =
        await manager.saveCroppedConversation(original, const Duration(milliseconds: 2125), const Duration(seconds: 5));
    final view = IntegrationRecording.fromConversation(copy);
    final omi = OmiCloudConnector(prefs);
    expect(omi.canSend(view), isTrue);
    final bytes = File(view.opusFrameSidecarPath).readAsBytesSync();
    final dynamic nativeLibrary = DynamicLibrary.open(libraryPath);
    initOpus(nativeLibrary);
    final decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
    var decodedSamples = 0;
    try {
      for (var offset = 0; offset < bytes.length;) {
        final length = ByteData.sublistView(bytes).getUint32(offset, Endian.little);
        final decoded = decoder.decode(input: Uint8List.sublistView(bytes, offset + 4, offset + 4 + length));
        expect(decoded, hasLength(320));
        decodedSamples += decoded.length;
        offset += 4 + length;
      }
    } finally {
      decoder.destroy();
    }
    expect(decodedSamples, greaterThanOrEqualTo(2875 * 16));
    final segments = await OmiApiClient.buildSegments(File(view.opusFrameSidecarPath));
    expect(segments.single.$1, endsWith('_${copy.startTime.millisecondsSinceEpoch ~/ 1000}.bin'));
    await prefs.markOmiSynced(view.opusFrameSidecarPath);
    anchor(DateTime(2026, 9, 30, 12));
    await RecordingsManager.applyClockAnchors();
    var moved = (await library())[copy.uploadKey]!;
    var movedView = IntegrationRecording.fromConversation(moved);
    expect(movedView.hasOpusFrameSidecar, isTrue);
    expect(omi.hasDelivered(movedView), isTrue);
    expect(File(view.opusFrameSidecarPath).existsSync(), isFalse);
    await RecordingsManager.revertClockCorrection(moved);
    moved = (await library())[copy.uploadKey]!;
    movedView = IntegrationRecording.fromConversation(moved);
    expect(moved.startTime, copy.startTime);
    expect(omi.hasDelivered(movedView), isTrue);
    expect(movedView.hasOpusFrameSidecar, isTrue);
    await RecordingsManager.deleteConversation(moved);
    expect(File(movedView.opusFrameSidecarPath).existsSync(), isFalse);
  }, skip: !Platform.isWindows);
}
