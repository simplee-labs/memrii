import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_adapter.dart';

class DeviceUtils {
  /// The picture of a [type] device (the Omi unless told otherwise), lit when [isConnected].
  static String getDeviceImagePathWithState({required bool isConnected, DeviceType type = DeviceType.omi}) {
    return DeviceAdapters.forType(type).imagePath(connected: isConnected);
  }
}
