/// How a discovered device is reached. Persisted by index inside the stored device, so
/// values are only ever appended. (Upstream's never-used `watch` kind, the last value, was
/// removed; nothing was ever stored with it, and an unknown index now reads as bluetooth.)
enum DeviceLocatorKind {
  bluetooth,
}

class DeviceLocator {
  final DeviceLocatorKind kind;
  final String? deviceId;

  const DeviceLocator({
    required this.kind,
    this.deviceId,
  });

  factory DeviceLocator.bluetooth({required String deviceId}) {
    return DeviceLocator(kind: DeviceLocatorKind.bluetooth, deviceId: deviceId);
  }

  factory DeviceLocator.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    return DeviceLocator(
      kind: kind is int && kind >= 0 && kind < DeviceLocatorKind.values.length
          ? DeviceLocatorKind.values[kind]
          : DeviceLocatorKind.bluetooth,
      deviceId: json['deviceId'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'kind': kind.index,
      'deviceId': deviceId,
    };
  }
}
