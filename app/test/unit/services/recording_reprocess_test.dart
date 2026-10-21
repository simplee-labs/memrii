import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/integration_coordinator.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/recordings_isolate_worker.dart' show checkpointVersion;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../recordings_manager_test.dart' show MockPathProvider;
import 'recording_crop_test.dart' show pcmRecording;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;
  late RecordingsManager manager;
  late SharedPreferencesUtil prefs;
  final start = DateTime.utc(2026, 9, 30, 12);

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil()
      ..manualMode = true
      ..vadEnabled = false
      ..audioSaveFormat = 'wav';
    docs = Directory.systemTemp.createTempSync('recording_reprocess');
    PathProviderPlatform.instance = MockPathProvider()..tempPath = docs.path;
    RecordingsManager.incompleteBinResolverForTest = () async => const {};
    RecordingsManager.reprocessSyncInFlightForTest = () => false;
    manager = RecordingsManager();
  });

  tearDown(() {
    RecordingsManager.incompleteBinResolverForTest = null;
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

  RecordingsController controller() {
    final changes = ValueNotifier<int>(0);
    final integrations = IntegrationCoordinator(
      connectors: const [],
      prefs: prefs,
      loadRecordings: () async =>
          IntegrationSnapshot(await manager.getBatches(), await manager.getMarkerConversations()),
      recordingChanges: changes,
      isProcessing: () => RecordingsManager.recordingsUnsettled,
      isPipelineIdle: () => true,
      checkOnWifi: () async => true,
    );
    final controller = RecordingsController(integrations: integrations);
    addTearDown(() {
      controller.dispose();
      integrations.dispose();
      changes.dispose();
    });
    return controller;
  }

  for (final entryPoint in ['player', 'list', 'bulk']) {
    test('deleting the original through $entryPoint cannot resurrect it while a crop remains', () async {
      final raw = writeBin(start);
      final original = oldRecording(bins: [relativeBin(start)]);
      final crop =
          await manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5));
      if (entryPoint == 'player') {
        await RecordingsManager.deleteConversation(original);
      } else {
        final ctl = controller();
        await ctl.reloadBatchesSilently();
        await ctl.deleteConversations([original], reload: entryPoint == 'list');
      }
      expect(original.file.existsSync(), isFalse);
      expect(raw.existsSync(), isFalse, reason: 'crops do not own the original raw bins');
      expect(crop.file.existsSync(), isTrue);
      await RecordingsManager.forceProcessAll();
      expect((await recordings()).single.uploadKey, crop.uploadKey);
    });
  }

  test('source bins survive while another original or draft remains in the session', () async {
    final raw = writeBin(start);
    final original = oldRecording(bins: [relativeBin(start)]);
    final draft = oldRecording(time: start.add(const Duration(minutes: 1)), draft: true);
    final crop =
        await manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5));
    await RecordingsManager.deleteConversation(crop);
    expect(raw.existsSync(), isTrue, reason: 'deleting a copy must not purge source audio');
    await RecordingsManager.deleteConversation(original);
    expect(raw.existsSync(), isTrue, reason: 'an open draft still needs the source bins');
    await RecordingsManager.deleteConversation(draft);
    expect(raw.existsSync(), isFalse);
  });

  test('full reprocessing removes every old edit and rebuilds all consumed bins from the beginning', () async {
    final bins = [writeBin(start), writeBin(start.add(const Duration(minutes: 5)))];
    final sourceBytes = bins.map((b) => b.readAsBytesSync()).toList();
    final original = oldRecording(bins: [relativeBin(start)]);
    final crop =
        await manager.saveCroppedConversation(original, const Duration(seconds: 2), const Duration(seconds: 5));
    final draft = oldRecording(time: start.subtract(const Duration(minutes: 2)), draft: true);
    final unmatched = oldRecording(time: start.subtract(const Duration(days: 3)));
    final opus = File(RecordingsManager.opusFrameSidecarPathFor(original.file))..writeAsBytesSync([1, 2, 3]);
    await manager.writeMarkerEdlTest(docs.path, {
      'filename': p.basename(original.file.path),
      'markerMs': start.millisecondsSinceEpoch,
      'offsetMs': 0,
      'durationMs': 10000,
      'isHighPriority': true,
    });
    await manager.setConversationPriority(original, false);
    final tombstone = File(p.join(original.file.parent.path, 'marker_${start.millisecondsSinceEpoch}.edl'));
    final edit = jsonDecode(tombstone.readAsStringSync()) as Map<String, dynamic>;
    edit.addAll({'cropStartMs': 5000, 'cropEndMs': 12000, 'userSaved': true});
    tombstone.writeAsStringSync(jsonEncode(edit));
    File(p.join(original.file.parent.path, 'discards.jsonl')).writeAsStringSync('{"old":true}\n');
    final temp = Directory(p.join(docs.path, 'processing_temp', 'combined'))..createSync(recursive: true);
    File(p.join(temp.path, 'stale.wav')).writeAsBytesSync([1, 2, 3]);
    File(p.join(docs.path, 'vad_checkpoint.json')).writeAsStringSync(jsonEncode({
      'version': checkpointVersion,
      'lastIndex': 0,
      'paths': bins.map((b) => b.path).toList(),
      'state': {},
      'pendingDeletes': [bins.first.path],
    }));
    File(p.join(docs.path, 'vad_priority_latch.json')).writeAsStringSync('{"old":true}');
    prefs.pendingRefiles = '{"old":{}}';
    prefs.clockCorrectionLedger = '{"42":{"o":0,"r":true}}';
    prefs.lateMergeNotices = ['1:2'];
    prefs.heypocketUploadedFiles = [original.uploadKey!, crop.uploadKey!];
    await prefs.markOmiSynced(opus.path);

    await RecordingsManager.forceProcessAll(reprocessCovered: true);

    final rebuilt = await recordings();
    expect(rebuilt, hasLength(2));
    expect(rebuilt.map((c) => c.startTime.millisecondsSinceEpoch).toSet(),
        {start.millisecondsSinceEpoch, start.add(const Duration(minutes: 5)).millisecondsSinceEpoch});
    expect(rebuilt.every((c) => !c.isCropped && c.uploadKey != original.uploadKey), isTrue);
    expect((await manager.getBatches()).expand((b) => b.draftRecordings), isEmpty);
    for (final old in [crop, draft, unmatched]) {
      expect(old.file.existsSync(), isFalse);
      expect(File(p.setExtension(old.file.path, '.meta')).existsSync(), isFalse);
    }
    expect(opus.existsSync(), isFalse);
    expect(File(p.join(temp.path, 'stale.wav')).existsSync(), isFalse);
    for (var i = 0; i < bins.length; i++) {
      expect(bins[i].readAsBytesSync(), sourceBytes[i], reason: 'consumed input is kept for another full rebuild');
    }
    final markers = await manager.getMarkerConversations();
    expect(markers, hasLength(2));
    expect(markers.every((m) => m.isHighPriority && !m.userSaved && m.cropStartMs == 0 && !m.isPending), isTrue);
    final regenerated = jsonDecode(tombstone.readAsStringSync()) as Map<String, dynamic>;
    expect(regenerated.containsKey('priorityOverride'), isFalse);
    expect(regenerated['cropStartMs'], 0);
    expect(regenerated['cropEndMs'], isNot(12000));
    expect(prefs.pendingRefiles, isEmpty);
    expect(prefs.clockCorrectionLedger, isEmpty);
    expect(prefs.lateMergeNotices, isEmpty);
    expect(prefs.heypocketUploadedFiles, isEmpty);
    expect(prefs.isOmiSynced(opus.path), isFalse);
    expect(File(p.join(docs.path, 'vad_checkpoint.json')).existsSync(), isFalse);
    expect(File(p.join(docs.path, 'vad_priority_latch.json')).existsSync(), isFalse);
    expect(RecordingsManager.recordingsUnsettled, isFalse);
  });

  test('reprocessing restores missing adjustment and discard data without overwriting live bins', () async {
    final live = writeBin(start);
    final originalBytes = live.readAsBytesSync();
    final stale = writeBin(start, root: 'adjustment_mode_segments')..writeAsBytesSync([1]);
    final adjusted = writeBin(start.add(const Duration(minutes: 5)), root: 'adjustment_mode_segments');
    final discarded = writeBin(start.add(const Duration(minutes: 10)), root: 'discarded_segments');
    final archivedBytes = [adjusted.readAsBytesSync(), discarded.readAsBytesSync()];
    oldRecording();

    await RecordingsManager.forceProcessAll(reprocessCovered: true);

    expect(await recordings(), hasLength(3));
    expect(live.readAsBytesSync(), originalBytes);
    expect(stale.readAsBytesSync(), [1]);
    for (var i = 0; i < 2; i++) {
      final archive = [adjusted, discarded][i];
      expect(archive.readAsBytesSync(), archivedBytes[i]);
      final raw = File(p.join(docs.path, 'raw_segments', p.relative(archive.path, from: archive.parent.parent.path)));
      expect(raw.readAsBytesSync(), archivedBytes[i]);
    }
    expect(docs.listSync(recursive: true).any((f) => f.path.endsWith('.reprocess.tmp')), isFalse);
  });

  test('a second rebuild uses current settings instead of the old recording metadata', () async {
    writeBin(start);
    prefs.manualMode = true;
    await RecordingsManager.forceProcessAll(reprocessCovered: true);
    final first = (await recordings()).single;
    expect(first.recordedManual, isTrue);
    prefs.manualMode = false;
    await RecordingsManager.forceProcessAll(reprocessCovered: true);
    final second = (await recordings()).single;
    expect(second.recordedManual, isFalse);
    expect(await recordings(), hasLength(1));
    expect(await manager.getMarkerConversations(), hasLength(1));
  });

  test('an empty raw placeholder is restored from available archived data', () async {
    final archive = writeBin(start, root: 'adjustment_mode_segments');
    final raw = File(p.join(docs.path, 'raw_segments', relativeBin(start)));
    raw.parent.createSync(recursive: true);
    raw.writeAsBytesSync([]);
    oldRecording();
    await RecordingsManager.forceProcessAll(reprocessCovered: true);
    expect(raw.readAsBytesSync(), archive.readAsBytesSync());
    expect(await recordings(), hasLength(1));
  });

  test('an active sync prevents reset while source data is still changing', () async {
    final original = oldRecording();
    writeBin(start);
    RecordingsManager.reprocessSyncInFlightForTest = () => true;
    await expectLater(RecordingsManager.forceProcessAll(reprocessCovered: true), throwsStateError);
    expect(original.file.existsSync(), isTrue);
    expect(RecordingsManager.recordingsUnsettled, isFalse);
  });

  test('no available source data leaves existing recordings and crops intact', () async {
    final original = oldRecording();
    final copy = await manager.saveCroppedConversation(original, Duration.zero, const Duration(seconds: 5));
    await expectLater(RecordingsManager.forceProcessAll(reprocessCovered: true), throwsStateError);
    expect(original.file.existsSync(), isTrue);
    expect(copy.file.existsSync(), isTrue);
    expect(await recordings(), hasLength(2));
    expect(RecordingsManager.recordingsUnsettled, isFalse);
  });

  test('source restoration failure leaves the current library intact', () async {
    final original = oldRecording();
    final archive = writeBin(start, root: 'adjustment_mode_segments');
    final blocker = File(p.join(docs.path, 'raw_segments', p.basename(archive.parent.path)));
    blocker.parent.createSync(recursive: true);
    blocker.writeAsBytesSync([1]);
    await expectLater(RecordingsManager.forceProcessAll(reprocessCovered: true), throwsA(isA<FileSystemException>()));
    expect(original.file.existsSync(), isTrue);
    expect(archive.existsSync(), isTrue);
    expect(RecordingsManager.recordingsUnsettled, isFalse);
  });

  test('reset waits for uploads and rejects another processing run', () async {
    final original = oldRecording();
    writeBin(start);
    RecordingsManager.noteUploadStarted(original.file);
    await expectLater(RecordingsManager.forceProcessAll(reprocessCovered: true), throwsStateError);
    expect(original.file.existsSync(), isTrue);
    RecordingsManager.noteUploadFinished(original.file);

    final rebuild = RecordingsManager.forceProcessAll(reprocessCovered: true);
    expect(RecordingsManager.isProcessingAny, isTrue);
    await expectLater(RecordingsManager.forceProcessAll(reprocessCovered: true), throwsStateError);
    await rebuild;
    expect(await recordings(), hasLength(1));
  });

  test('cancelling during preparation keeps the old library', () async {
    final original = oldRecording();
    writeBin(start);
    final rebuild = RecordingsManager.forceProcessAll(reprocessCovered: true);
    final cancelled = expectLater(rebuild, throwsStateError);
    RecordingsManager.cancelProcessing();
    await cancelled;
    expect(original.file.existsSync(), isTrue);
    expect((await recordings()).single.uploadKey, original.uploadKey);
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
