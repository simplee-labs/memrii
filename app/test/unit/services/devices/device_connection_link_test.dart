import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

class _Transport extends DeviceTransport {
  final states = StreamController<DeviceTransportState>();

  @override
  Stream<DeviceTransportState> get connectionStateStream => states.stream;

  @override
  Future<void> connect({bool requiresBond = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection extends DeviceConnection {
  _Connection(_Transport t) : super(BtDevice(id: '1', name: 'Omi', type: DeviceType.omi, rssi: 0), t);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // The recordings pipeline trusts a file list and a session read to describe one session
  // only when both were answered on one link: the Omi changes session by restarting, which
  // ends the link.
  test('every link gets a number of its own; one link keeps its number', () async {
    final t = _Transport();
    final c = _Connection(t);
    await c.connect();
    Future<void> say(DeviceTransportState s) async {
      t.states.add(s);
      await Future<void>.delayed(Duration.zero);
    }

    await say(DeviceTransportState.connected);
    final first = c.link;
    expect(first, greaterThan(0));
    await say(DeviceTransportState.connected);
    expect(c.link, first, reason: 'no new link without a drop');
    await say(DeviceTransportState.disconnected);
    expect(c.link, first, reason: 'an answer cannot arrive with no link, so the number can stay');
    await say(DeviceTransportState.connected);
    final second = c.link;
    expect(second, greaterThan(first));
    await say(DeviceTransportState.connecting);
    await say(DeviceTransportState.connected);
    expect(c.link, greaterThan(second), reason: 'a reconnect is a new link');

    final other = _Connection(_Transport());
    await other.connect();
    (other.transport as _Transport).states.add(DeviceTransportState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(other.link, greaterThan(c.link), reason: 'counted across connections');
  });
}
