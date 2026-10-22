import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';

/// While mcumgr flashes the Omi it shares the link with this app, and Android sends one
/// request at a time per link, so the app's own requests are held off for the update
/// (NativeBleTransport.yieldLinkToFirmwareUpdate). These pin what that hold does: nothing
/// new reaches native, a request native has not answered yet is waited for, the wait is
/// bounded, and reclaiming the link lets traffic through again.
///
/// The hold and the count are static, shared by every transport, so each test leaves both
/// as it found them: the link reclaimed and every native request answered.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const address = 'handoff-test';
  const service = '19b10010-e8f2-537e-4f6c-d104768a1214';
  const characteristic = '19b10012-e8f2-537e-4f6c-d104768a1214';
  const ok = <Object?>[null];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = ['manageDevice', 'unmanageDevice', 'readCharacteristic', 'writeCharacteristic'];

  late NativeBleTransport transport;
  late int nativeReads;
  late int nativeWrites;

  /// Native's answer to the next read, completed by the test when native should answer.
  late Completer<Object?> readAnswer;

  BasicMessageChannel<Object?> channel(String method) =>
      BasicMessageChannel<Object?>('dev.flutter.pigeon.omi_pigeon.BleHostApi.$method', BleHostApi.pigeonChannelCodec);

  void answerRead() {
    if (readAnswer.isCompleted) return;
    readAnswer.complete(<Object?>[
      Uint8List.fromList([7])
    ]);
  }

  setUp(() async {
    nativeReads = 0;
    nativeWrites = 0;
    readAnswer = Completer<Object?>();
    messenger.setMockDecodedMessageHandler<Object?>(channel('manageDevice'), (_) async => ok);
    messenger.setMockDecodedMessageHandler<Object?>(channel('unmanageDevice'), (_) async => ok);
    messenger.setMockDecodedMessageHandler<Object?>(channel('readCharacteristic'), (_) {
      nativeReads++;
      return readAnswer.future;
    });
    messenger.setMockDecodedMessageHandler<Object?>(channel('writeCharacteristic'), (_) async {
      nativeWrites++;
      return ok;
    });
    transport = NativeBleTransport(address);
    final connecting = transport.connect();
    await Future<void>.delayed(Duration.zero);
    BleBridge.instance.onDeviceReady(address, [
      BleService(uuid: service, characteristicUuids: const [characteristic]),
    ]);
    await connecting;
  });

  tearDown(() async {
    NativeBleTransport.reclaimLinkFromFirmwareUpdate();
    answerRead();
    await Future<void>.delayed(Duration.zero);
    await transport.dispose();
    for (final method in methods) {
      messenger.setMockDecodedMessageHandler<Object?>(channel(method), null);
    }
  });

  test('while an update has the link, reads and writes are not sent', () async {
    expect(await NativeBleTransport.yieldLinkToFirmwareUpdate(), isTrue);
    expect(NativeBleTransport.linkYieldedToFirmwareUpdate, isTrue);

    // Refused the way an Omi that does not answer is reported, which callers handle.
    expect(await transport.readCharacteristic(service, characteristic), isEmpty);
    await expectLater(transport.writeCharacteristic(service, characteristic, [0x32]), throwsStateError);

    expect(nativeReads, 0);
    expect(nativeWrites, 0);
  });

  test('a read already sent is waited for before the update starts', () async {
    final read = transport.readCharacteristic(service, characteristic);
    await Future<void>.delayed(Duration.zero);
    expect(nativeReads, 1);
    expect(NativeBleTransport.unansweredNativeOps, 1);

    var yielded = false;
    final yielding = NativeBleTransport.yieldLinkToFirmwareUpdate().then((drained) {
      yielded = true;
      return drained;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(yielded, isFalse, reason: 'native has not answered the read yet');

    answerRead();
    expect(await yielding, isTrue);
    expect(await read, [7]);
    expect(NativeBleTransport.unansweredNativeOps, 0);
  });

  test('the wait for unanswered requests is bounded', () async {
    unawaited(transport.readCharacteristic(service, characteristic));
    await Future<void>.delayed(Duration.zero);

    final drained = await NativeBleTransport.yieldLinkToFirmwareUpdate(settle: const Duration(milliseconds: 30));

    expect(drained, isFalse);
    expect(NativeBleTransport.unansweredNativeOps, 1, reason: 'still counted until native answers it');
    expect(NativeBleTransport.linkYieldedToFirmwareUpdate, isTrue, reason: 'held regardless; the update goes ahead');
  });

  test('reclaiming the link lets reads and writes through again', () async {
    await NativeBleTransport.yieldLinkToFirmwareUpdate();
    NativeBleTransport.reclaimLinkFromFirmwareUpdate();

    answerRead();
    expect(await transport.readCharacteristic(service, characteristic), [7]);
    await transport.writeCharacteristic(service, characteristic, [0x32]);

    expect(nativeReads, 1);
    expect(nativeWrites, 1);
  });
}
