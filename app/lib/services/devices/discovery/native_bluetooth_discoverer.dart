import 'dart:async';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_adapter.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';
import 'package:omi/utils/logger.dart';

class NativeBluetoothDiscoverer extends DeviceDiscoverer {
  final BleHostApi _hostApi = BleHostApi();

  @override
  String get name => 'NativeBluetooth';

  @override
  bool get isSupported => true;

  @override
  Future<DeviceDiscoveryResult> discover({int timeout = 5}) async {
    final results = <BlePeripheral>[];

    final previousCallback = BleBridge.instance.peripheralDiscoveredCallback;

    BleBridge.instance.peripheralDiscoveredCallback = (BlePeripheral peripheral) {
      // Logger.debug('NativeBluetoothDiscoverer: Discovered peripheral: ${peripheral.name} (${peripheral.uuid})');
      if (!results.any((r) => r.uuid == peripheral.uuid)) {
        results.add(peripheral);
      }
    };

    try {
      _hostApi.startScan(timeout, []);
      await Future.delayed(Duration(seconds: timeout));
      _hostApi.stopScan();

      final devices = <BtDevice>[];
      for (final p in results) {
        final adapter = DeviceAdapters.forPeripheral(name: p.name, serviceUuids: p.serviceUuids);
        if (adapter != null) devices.add(_peripheralToDevice(p, adapter));
      }
      return DeviceDiscoveryResult(devices: devices);
    } catch (e) {
      Logger.debug('NativeBluetoothDiscoverer: scan error: $e');
      try {
        _hostApi.stopScan();
      } catch (_) {}
      return const DeviceDiscoveryResult(devices: []);
    } finally {
      BleBridge.instance.peripheralDiscoveredCallback = previousCallback;
    }
  }

  @override
  void stop() {
    try {
      _hostApi.stopScan();
    } catch (e) {
      Logger.debug('NativeBluetoothDiscoverer: stop scan error: $e');
    }
  }

  /// Which peripherals count as a supported device is each adapter's call
  /// ([DeviceAdapter.matchesPeripheral]); the scan itself is device-independent.
  static BtDevice _peripheralToDevice(BlePeripheral p, DeviceAdapter adapter) {
    return BtDevice(
      name: p.name,
      id: p.uuid,
      type: adapter.type,
      rssi: p.rssi,
      locator: DeviceLocator.bluetooth(deviceId: p.uuid),
    );
  }
}
