import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/pages/dfuota/firmware_mixin.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';

/// An mcumgr attempt that fails before any firmware was sent is tried once more on its
/// own (FirmwareMixin._onMcuAttemptFailed): the opening handshake gives up on a request
/// after 5 s, and on a link shared with the app one can wait that long. Nothing has been
/// written to the Omi by then, so the retry is safe. Once the upload has begun, a failure
/// is the user's to retry. Either way the app's own Bluetooth traffic is held off only
/// while an attempt runs, and given back when the update ends.
///
/// mcumgr is replaced by fakes at its factory, so what runs is the mixin's real attempt
/// logic: its stream handling, retry decision and teardown.
class _FakeDeviceProvider extends ChangeNotifier implements DeviceProvider {
  bool firmwareStateReset = false;

  @override
  void resetFirmwareUpdateState() => firmwareStateReset = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLogger implements mcumgr.FirmwareUpdateLogger {
  @override
  Stream<mcumgr.McuLogMessage> get logMessageStream => const Stream.empty();

  @override
  Future<List<mcumgr.McuLogMessage>> readLogs({bool clearLogs = false}) async => const [];

  @override
  Future<void> clearLogs() async {}
}

/// One mcumgr session. The test drives it the way the plugin would: state changes,
/// progress, or the stream error that reports a failure.
class _FakeManager implements mcumgr.FirmwareUpdateManager {
  final _states = StreamController<mcumgr.FirmwareUpgradeState>.broadcast();
  final _progress = StreamController<mcumgr.ProgressUpdate>.broadcast();
  int updateCalls = 0;
  bool killed = false;

  void fail(String error) => _states.addError(error);
  void reach(mcumgr.FirmwareUpgradeState state) => _states.add(state);
  void sent(int bytes, int imageSize) => _progress.add(mcumgr.ProgressUpdate(bytes, imageSize, DateTime(2026)));

  @override
  final mcumgr.FirmwareUpdateLogger logger = _FakeLogger();

  @override
  Stream<mcumgr.ProgressUpdate> get progressStream => _progress.stream;

  @override
  Stream<bool>? get updateInProgressStream => null;

  @override
  Stream<mcumgr.FirmwareUpgradeState> setup() => _states.stream;

  @override
  Stream<mcumgr.FirmwareUpgradeState>? get updateStateStream => _states.stream;

  @override
  Future<void> update(List<mcumgr.Image> images,
      {mcumgr.FirmwareUpgradeConfiguration configuration = const mcumgr.FirmwareUpgradeConfiguration()}) async {
    updateCalls++;
  }

  @override
  Future<void> updateWithImageData({
    required Uint8List imageData,
    Uint8List? hash,
    mcumgr.FirmwareUpgradeConfiguration? configuration,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<bool> inProgress() async => false;

  @override
  Future<bool> isPaused() async => false;

  @override
  Future<void> kill() async {
    killed = true;
    await _states.close();
    await _progress.close();
  }

  @override
  Future<List<mcumgr.ImageSlot>?> readImageList() async => null;
}

class _FakeFactory implements mcumgr.FirmwareUpdateManagerFactory {
  final managers = <_FakeManager>[];

  @override
  Future<mcumgr.FirmwareUpdateManager> getUpdateManager(String deviceId) async {
    final manager = _FakeManager();
    managers.add(manager);
    return manager;
  }
}

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with FirmwareMixin<_Host> {
  final factory = _FakeFactory();

  @override
  mcumgr.FirmwareUpdateManagerFactory get managerFactory => factory;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final btDevice = BtDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'Omi', type: DeviceType.omi, rssi: 0);
  final images = [mcumgr.Image(image: 0, data: Uint8List(100))];
  const failed = 'Firmware update failed. Please try again.';

  late _FakeDeviceProvider provider;

  setUp(() async {
    // A final failure releases the update wakelocks, which reads Keep Screen On and
    // toggles the screen wakelock.
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    await SharedPreferencesUtil.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
    provider = _FakeDeviceProvider();
  });

  tearDown(NativeBleTransport.reclaimLinkFromFirmwareUpdate);

  Future<_HostState> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<DeviceProvider>.value(value: provider, child: const _Host()));
    return tester.state<_HostState>(find.byType(_Host));
  }

  /// Runs the first attempt up to mcumgr's update call.
  Future<_FakeManager> startAttempt(WidgetTester tester, _HostState host) async {
    unawaited(host.runMcuAttempt(btDevice, images));
    await tester.pump();
    final manager = host.factory.managers.last;
    expect(manager.updateCalls, 1);
    return manager;
  }

  testWidgets('a failure before any firmware was sent is retried once, without an error', (tester) async {
    final host = await pumpHost(tester);
    final first = await startAttempt(tester, host);
    expect(NativeBleTransport.linkYieldedToFirmwareUpdate, isTrue, reason: 'held while mcumgr runs');

    first.fail('Transaction 2 timed out without receiving a response');
    await tester.pump();

    expect(host.installErrorMessage, isNull);
    expect(provider.firmwareStateReset, isFalse);
    expect(first.killed, isTrue);
    expect(host.factory.managers, hasLength(1), reason: 'the retry waits out its pause first');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(host.factory.managers, hasLength(2));
    expect(host.factory.managers.last.updateCalls, 1);
    expect(NativeBleTransport.linkYieldedToFirmwareUpdate, isTrue);

    await host.killMcuUpdateManager(); // ends the retry's session and its stall watchdog
  });

  testWidgets('the retry failing too ends the update and gives the link back', (tester) async {
    final host = await pumpHost(tester);
    final first = await startAttempt(tester, host);
    first.fail('Transaction 2 timed out without receiving a response');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    host.factory.managers.last.fail('Transaction 2 timed out without receiving a response');
    await tester.pump();

    expect(host.installErrorMessage, failed);
    expect(provider.firmwareStateReset, isTrue);
    expect(host.factory.managers.last.killed, isTrue);
    expect(NativeBleTransport.linkYieldedToFirmwareUpdate, isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(host.factory.managers, hasLength(2), reason: 'one retry, not two');
  });

  testWidgets('a failure once the upload has begun is left to the user', (tester) async {
    final host = await pumpHost(tester);
    final first = await startAttempt(tester, host);

    first.reach(mcumgr.FirmwareUpgradeState.upload);
    first.sent(40, 100);
    await tester.pump();
    first.fail('Disconnected');
    await tester.pump();

    expect(host.installErrorMessage, failed);
    expect(provider.firmwareStateReset, isTrue);
    expect(NativeBleTransport.linkYieldedToFirmwareUpdate, isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(host.factory.managers, hasLength(1));
  });

  testWidgets('a second error from the failed attempt does not end the retry', (tester) async {
    final host = await pumpHost(tester);
    final first = await startAttempt(tester, host);

    first.fail('Transaction 2 timed out without receiving a response');
    first.fail('Disconnected');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(host.factory.managers, hasLength(2));
    expect(host.installErrorMessage, isNull, reason: 'the second error belonged to the retired attempt');
    expect(provider.firmwareStateReset, isFalse);

    await host.killMcuUpdateManager();
  });
}
