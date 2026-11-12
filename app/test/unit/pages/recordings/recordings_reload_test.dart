import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/integration_coordinator.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../recordings_manager_test.dart' show MockPathProvider;

class _IdleSync implements SDCardWalSync {
  @override
  bool get isSyncing => false;
  @override
  bool get hasDevice => true;
  @override
  void setGlobalProgressListener(IWalSyncProgressListener? value) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Delete Day held until [release] completes, so a second one can be tried meanwhile.
class _SlowDeleteManager implements RecordingsManager {
  final release = Completer<void>();
  final deleted = <String>[];

  @override
  Future<void> deleteDay(Batch batch) async {
    deleted.add(batch.dateString);
    await release.future;
  }

  @override
  Future<List<Batch>> getBatches() async => const [];

  @override
  Future<List<MarkerConversation>> getMarkerConversations() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
    await SharedPreferencesUtil.init();
    await ServiceManager.init();
  });
  tearDownAll(() => ServiceManager.instance().integrations.dispose());

  /// A controller on an empty archive, its first list loaded.
  Future<RecordingsController> controllerOf({RecordingsManager? manager}) async {
    final temp = Directory.systemTemp.createTempSync('recordings_reload');
    PathProviderPlatform.instance = MockPathProvider()..tempPath = temp.path;
    addTearDown(() => temp.deleteSync(recursive: true));
    final coordinator = IntegrationCoordinator(
      connectors: const [],
      prefs: SharedPreferencesUtil(),
      loadRecordings: () async => const IntegrationSnapshot([], []),
      recordingChanges: RecordingsManager.recordingsChangeNotifier,
      isProcessing: () => RecordingsManager.recordingsUnsettled,
      isPipelineIdle: () => true,
      checkOnWifi: () async => true,
      showUploadNotification: (_) {},
    );
    addTearDown(coordinator.dispose);
    final controller = RecordingsController(integrations: coordinator, walSync: _IdleSync(), manager: manager);
    addTearDown(controller.dispose);

    controller.init();
    await controller.reloadBatchesSilently(); // the first list, after its spinner
    expect(controller.isLoading, isFalse);
    expect(controller.batches, isEmpty);
    return controller;
  }

  test('a reload keeps the list on screen, and a burst of changes ends on the last one', () async {
    final controller = await controllerOf();
    final temp = Directory((await PathProviderPlatform.instance.getApplicationDocumentsPath())!);

    final spinner = <bool>[];
    controller.addListener(() => spinner.add(controller.isLoading));
    // Several change notices in a row, as Delete Day's commits make, with the archive
    // changing among them.
    for (var i = 0; i < 4; i++) {
      RecordingsManager.notifyRecordingsChanged();
    }
    File('${temp.path}/raw_segments/1780358400/1780358400_2.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    RecordingsManager.notifyRecordingsChanged();
    await controller.reloadBatchesSilently();
    expect(spinner, isNot(contains(true)), reason: 'the list stays on screen while it reloads');
    expect(controller.batches.single.rawSegments, hasLength(1), reason: 'the last change is the one shown');
  });

  // Delete Day first works out what crosses midnight, which takes a while when audio has
  // just arrived. A second Delete Day meanwhile is turned away, not queued behind it (on a
  // device, one confirmed twice ran twice).
  test('a second Delete Day while one runs is turned away; the page can say which day is deleting', () async {
    final manager = _SlowDeleteManager();
    final controller = await controllerOf(manager: manager);
    final day = Batch(
      dateString: '2026-11-11',
      date: DateTime(2026, 11, 11),
      rawSegments: const [],
      draftRecordings: const [],
      finalizedRecordings: const [],
      markerTimestamps: const [],
      discards: const [],
    );
    final first = controller.deleteDay(day);
    await Future<void>.delayed(Duration.zero);
    expect(controller.deletingDay, '2026-11-11');
    expect(await controller.deleteDay(day), isFalse);
    manager.release.complete();
    expect(await first, isTrue);
    expect(manager.deleted, ['2026-11-11'], reason: 'deleted once');
    expect(controller.deletingDay, isNull);
    expect(await controller.deleteDay(day), isTrue, reason: 'once it is done, Delete Day runs again');
  });
}
