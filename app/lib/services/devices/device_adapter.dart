import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/omi/omi_device_adapter.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';

/// Everything memrii needs to know about one kind of capture device that is not already
/// expressed by [DeviceConnection].
///
/// The rest of the app — discovery, the connection pipeline, sync, processing — reaches a
/// device through this and through [DeviceConnection], and never through a concrete
/// device class. The Omi is the only adapter today ([OmiDeviceAdapter]); a second device
/// would be a second implementation registered in [DeviceAdapters.all], plus its own
/// [DeviceType] value.
///
/// Deliberately small. It covers the three places the app used to name the Omi directly
/// — recognising one in a scan, building its connection, drawing it — and nothing it
/// would have to guess at. In particular there is no generic capability model: the
/// features a device reports are a firmware bitfield only the Omi defines
/// ([OmiFeatures]), and the settings screens that read it are Omi screens.
abstract class DeviceAdapter {
  const DeviceAdapter();

  /// Persisted inside the stored [BtDevice] (by index), so a value, once shipped, must
  /// never be renumbered.
  DeviceType get type;

  /// What the user calls this device, e.g. "Omi".
  String get displayName;

  /// Whether a peripheral seen in a Bluetooth scan is one of this adapter's devices.
  bool matchesPeripheral({required String name, required List<String> serviceUuids});

  /// Builds the connection for [device] over [transport]. The transport, its retry and
  /// its reconnect behaviour are not the adapter's to choose — see [DeviceConnectionFactory].
  DeviceConnection createConnection(BtDevice device, DeviceTransport transport);

  /// Asset path of this device's picture, lit when [connected].
  String imagePath({required bool connected});
}

/// The adapters this build knows about.
class DeviceAdapters {
  DeviceAdapters._();

  static const List<DeviceAdapter> all = [OmiDeviceAdapter()];

  /// The adapter for [type]. Every [DeviceType] has one; a type without one is a build
  /// error waiting to happen, so this throws rather than guessing.
  static DeviceAdapter forType(DeviceType type) => all.firstWhere(
        (a) => a.type == type,
        orElse: () => throw StateError('no DeviceAdapter for $type'),
      );

  /// The adapter that claims a scanned peripheral, or null if none does.
  static DeviceAdapter? forPeripheral({required String name, required List<String> serviceUuids}) {
    for (final adapter in all) {
      if (adapter.matchesPeripheral(name: name, serviceUuids: serviceUuids)) return adapter;
    }
    return null;
  }
}

class DeviceConnectionFactory {
  /// The connection for [device], over the native BLE transport. The transport is chosen
  /// here rather than by the adapter because native owns connection retry and reconnect
  /// for every device — an adapter supplies the
  /// protocol spoken over the link, not the link.
  static DeviceConnection? create(BtDevice device, {bool requiresBond = true}) {
    final DeviceTransport transport = NativeBleTransport(device.id, requiresBond: requiresBond);
    return DeviceAdapters.forType(device.type).createConnection(device, transport);
  }
}
