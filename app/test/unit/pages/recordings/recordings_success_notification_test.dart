import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/integrations/integration_coordinator.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../recordings_manager_test.dart' show MockPathProvider;
import 'integration_upload_manager_test.dart' show FakeIntegration;

class _CompletedSync implements SDCardWalSync {
  @override
  bool get isSyncing => false;
  @override
  bool get hasDevice => true;
  @override
  Future<SyncLocalFilesResponse?> rotateAndSync({IWalSyncProgressListener? progress}) async =>
      SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);
  @override
  void setGlobalProgressListener(IWalSyncProgressListener? value) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('early success dismissal returns notification ownership to the active upload', () async {
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
    final temp = Directory.systemTemp.createTempSync('success_notification');
    PathProviderPlatform.instance = MockPathProvider()..tempPath = temp.path;
    await ServiceManager.init();
    addTearDown(() {
      ServiceManager.instance().integrations.dispose();
      RecordingsManager.isSuccessNotificationActive.value = false;
      temp.deleteSync(recursive: true);
    });

    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final destination = FakeIntegration('Cloud')..onUpload = (_) => gate.future;
    final notifications = <String>[];
    final coordinator = IntegrationCoordinator(
      connectors: [destination],
      prefs: SharedPreferencesUtil(),
      loadRecordings: () async => const IntegrationSnapshot([], []),
      recordingChanges: RecordingsManager.recordingsChangeNotifier,
      isProcessing: () => RecordingsManager.recordingsUnsettled,
      // Match the production service's predicate, including the success flag.
      isPipelineIdle: () =>
          !ServiceManager.instance().wal.getSyncs().isSyncing &&
          !RecordingsManager.recordingsUnsettled &&
          !RecordingsManager.isSuccessNotificationActive.value,
      checkOnWifi: () async => true,
      showUploadNotification: notifications.add,
    );
    addTearDown(coordinator.dispose);
    final controller = RecordingsController(integrations: coordinator, walSync: _CompletedSync());
    addTearDown(controller.dispose);

    await controller.startForcePipeline();
    expect(controller.spState, SyncProcessState.successUi);
    expect(RecordingsManager.isSuccessNotificationActive.value, isTrue);
    final c = Conversation(
      file: File('${temp.path}/recording.wav')..writeAsBytesSync([1, 2, 3]),
      startTime: DateTime(2026, 9, 1),
      duration: const Duration(minutes: 2),
      uploadKey: 'active-upload',
    );
    await coordinator.uploads.uploadConversation(c);
    expect(coordinator.uploads.hasInFlightUpload, isTrue);
    expect(notifications, isEmpty, reason: 'the success banner initially owns the notification');

    controller.dismissSuccess();
    expect(controller.spState, SyncProcessState.idle);
    expect(RecordingsManager.isSuccessNotificationActive.value, isFalse);
    expect(notifications, hasLength(1), reason: 'a single-request upload may never emit another progress update');
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}
