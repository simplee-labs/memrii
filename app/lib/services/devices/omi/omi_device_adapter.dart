import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/assets.gen.dart';
import 'package:omi/services/devices/device_adapter.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/omi/omi_connection.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

/// The Omi wearable running memrii firmware — the first, and so far only, supported
/// capture device.
///
/// Everything Omi-specific about talking to the device lives beside this file:
/// [OmiDeviceConnection] holds the GATT layout, the storage protocol and the capability
/// bitfield reads. The identifiers it matches on are compatibility contracts with devices
/// already in the field, not branding, and must not change with the product name.
class OmiDeviceAdapter extends DeviceAdapter {
  const OmiDeviceAdapter();

  @override
  DeviceType get type => DeviceType.omi;

  @override
  String get displayName => 'Omi';

  /// The firmware advertises the device name `Omi` plus the Settings service (0x0010) as a
  /// 128-bit UUID, so either identifies one. Both are what every Omi already flashed with
  /// this firmware sends; renaming the advertised name would make those devices invisible
  /// to a new app and a new firmware invisible to an old one.
  @override
  bool matchesPeripheral({required String name, required List<String> serviceUuids}) {
    if (name.toLowerCase().contains('omi')) return true;
    final settings = OmiDeviceConnection.settingsServiceUuid.toLowerCase();
    return serviceUuids.any((uuid) => uuid.toLowerCase() == settings);
  }

  @override
  DeviceConnection createConnection(BtDevice device, DeviceTransport transport) =>
      OmiDeviceConnection(device, transport);

  @override
  String imagePath({required bool connected}) =>
      connected ? Assets.images.omiWithoutRope.path : Assets.images.omiWithoutRopeTurnedOff.path;
}
