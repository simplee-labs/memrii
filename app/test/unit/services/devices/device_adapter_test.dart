import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_adapter.dart';
import 'package:omi/services/devices/omi/omi_connection.dart';
import 'package:omi/services/devices/omi/omi_device_adapter.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

class _NullTransport extends DeviceTransport {
  @override
  String get deviceId => 'AA:BB:CC:DD:EE:FF';
  @override
  Future<void> connect({bool requiresBond = false}) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<bool> isConnected() async => false;
  @override
  Future<bool> ping() async => false;
  @override
  Future<Stream<List<int>>> getCharacteristicStream(String s, String c) async => const Stream.empty();
  @override
  Future<List<int>> readCharacteristic(String s, String c) async => const [];
  @override
  Future<void> writeCharacteristic(String s, String c, List<int> data) async {}
  @override
  Stream<DeviceTransportState> get connectionStateStream => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

void main() {
  const omi = OmiDeviceAdapter();
  // The advertised Settings service, exactly as the firmware sends it (UUID128_ALL).
  const settingsUpper = '19B10010-E8F2-537E-4F6C-D104768A1214';

  group('OmiDeviceAdapter.matchesPeripheral — the identifiers devices in the field advertise', () {
    test('matches the advertised name, case-insensitively', () {
      expect(omi.matchesPeripheral(name: 'Omi', serviceUuids: const []), isTrue);
      expect(omi.matchesPeripheral(name: 'OMI', serviceUuids: const []), isTrue);
      expect(omi.matchesPeripheral(name: 'My Omi 2', serviceUuids: const []), isTrue);
    });

    test('matches the Settings service UUID in either case, even with no name', () {
      expect(omi.matchesPeripheral(name: '', serviceUuids: const [settingsUpper]), isTrue);
      expect(omi.matchesPeripheral(name: '', serviceUuids: [settingsUpper.toLowerCase()]), isTrue);
    });

    test('rejects an unrelated peripheral', () {
      expect(omi.matchesPeripheral(name: 'Pixel Buds', serviceUuids: const ['0000180f-0000-1000-8000-00805f9b34fb']),
          isFalse);
    });

    test('the UUID it matches is the one the connection addresses', () {
      // One definition: the adapter reads OmiDeviceConnection's constant rather than a copy.
      expect(OmiDeviceConnection.settingsServiceUuid.toUpperCase(), settingsUpper);
    });
  });

  group('DeviceAdapters', () {
    test('every DeviceType has an adapter', () {
      for (final type in DeviceType.values) {
        expect(DeviceAdapters.forType(type).type, type);
      }
    });

    test('forPeripheral picks the Omi adapter for an Omi and nothing for anything else', () {
      expect(DeviceAdapters.forPeripheral(name: 'Omi', serviceUuids: const []), isA<OmiDeviceAdapter>());
      expect(DeviceAdapters.forPeripheral(name: 'Headphones', serviceUuids: const []), isNull);
    });

    test('the Omi adapter builds the Omi connection', () {
      final device = BtDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'Omi', type: DeviceType.omi, rssi: 0);
      final conn = DeviceAdapters.forType(DeviceType.omi).createConnection(device, _NullTransport());
      expect(conn, isA<OmiDeviceConnection>());
      expect(conn.device.id, device.id);
    });
  });

  group('BtDevice type persistence', () {
    test('round-trips through toJson/fromJson', () {
      final device = BtDevice(id: 'x', name: 'Omi', type: DeviceType.omi, rssi: -40);
      expect(BtDevice.fromJson(device.toJson()).type, DeviceType.omi);
    });

    test('a device saved with an unreadable or out-of-range type reads back as an Omi', () {
      // Upgrade safety: every device stored so far is an Omi, whatever it carries here.
      for (final raw in [null, -1, 99, '0', 1.5]) {
        expect(DeviceType.fromIndex(raw), DeviceType.omi, reason: 'raw=$raw');
        expect(BtDevice.fromJson({'id': 'x', 'name': 'Omi', 'type': raw}).type, DeviceType.omi);
      }
    });
  });
}
