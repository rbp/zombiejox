import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'uuids.dart';

/// Thin wrapper over `flutter_blue_plus`. Connects, finds the JaxJox custom
/// service, and exposes RX notifications + a `writeTx` method.
class BleConnection {
  final BluetoothDevice device;
  late BluetoothCharacteristic _tx;
  late BluetoothCharacteristic _rx;
  BluetoothCharacteristic? _batteryLevel;

  StreamSubscription<List<int>>? _rxSub;
  final StreamController<List<int>> _rxController =
      StreamController.broadcast();

  Stream<List<int>> get rxStream => _rxController.stream;
  Stream<BluetoothConnectionState> get connectionState =>
      device.connectionState;

  BleConnection(this.device);

  Future<void> connect() async {
    // License.free per the flutter_blue_plus LICENSE: ZombieJox is GPLv3
    // open-source community software for orphaned hardware (see README), not
    // a commercial product. Revisit if distribution model changes.
    await device.connect(license: License.free, autoConnect: false);

    final services = await device.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid.str.toLowerCase() == JaxJoxUuids.service,
      orElse: () =>
          throw StateError('JaxJox service not found on ${device.remoteId}'),
    );
    _tx = svc.characteristics.firstWhere(
      (c) => c.uuid.str.toLowerCase() == JaxJoxUuids.txCharacteristic,
      orElse: () => throw StateError('TX characteristic not found'),
    );
    _rx = svc.characteristics.firstWhere(
      (c) => c.uuid.str.toLowerCase() == JaxJoxUuids.rxCharacteristic,
      orElse: () => throw StateError('RX characteristic not found'),
    );
    await _rx.setNotifyValue(true);
    _rxSub = _rx.onValueReceived.listen(_rxController.add);

    // Resolve the standard Battery Service from the same services list so
    // `readBatteryLevel` doesn't have to call `discoverServices()` a
    // second time. Null is fine — older firmwares don't expose it.
    _batteryLevel = services
        .where((s) => s.uuid.str.toLowerCase() == JaxJoxUuids.batteryService)
        .firstOrNull
        ?.characteristics
        .where((c) => c.uuid.str.toLowerCase() == JaxJoxUuids.batteryLevel)
        .firstOrNull;
  }

  Future<void> writeTx(List<int> bytes) =>
      _tx.write(bytes, withoutResponse: true);

  Future<int?> readBatteryLevel() async {
    final c = _batteryLevel;
    if (c == null) return null;
    final v = await c.read();
    return v.isEmpty ? null : v.first;
  }

  Future<void> disconnect() async {
    await _rxSub?.cancel();
    _rxSub = null;
    await _rxController.close();
    await device.disconnect();
  }
}
