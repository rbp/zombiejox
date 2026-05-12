import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'uuids.dart';

/// Thin wrapper over `flutter_blue_plus`. Connects, finds the JaxJox custom
/// service, and exposes RX notifications + a `writeTx` method.
///
/// [disconnect] is idempotent and best-effort: callers can invoke it after a
/// successful [connect], after a failed one, or twice in a row without
/// special casing. [connect] cleans up after itself if it throws partway
/// through, so a caller's `try/catch` doesn't need to know what step the
/// failure happened on.
class BleConnection {
  final BluetoothDevice device;
  BluetoothCharacteristic? _tx;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _batteryLevel;

  StreamSubscription<List<int>>? _rxSub;
  final StreamController<List<int>> _rxController =
      StreamController.broadcast();
  bool _closed = false;

  Stream<List<int>> get rxStream => _rxController.stream;
  Stream<BluetoothConnectionState> get connectionState =>
      device.connectionState;

  BleConnection(this.device);

  Future<void> connect() async {
    if (_closed) throw StateError('BleConnection is closed');
    try {
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
      await _rx!.setNotifyValue(true);
      _rxSub = _rx!.onValueReceived.listen(_rxController.add);

      // Resolve the standard Battery Service from the same services list so
      // `readBatteryLevel` doesn't have to call `discoverServices()` a
      // second time. Null is fine — older firmwares don't expose it.
      _batteryLevel = services
          .where((s) => s.uuid.str.toLowerCase() == JaxJoxUuids.batteryService)
          .firstOrNull
          ?.characteristics
          .where((c) => c.uuid.str.toLowerCase() == JaxJoxUuids.batteryLevel)
          .firstOrNull;
    } catch (_) {
      // Partial-init failure: tear down whatever we already brought up so the
      // caller's catch doesn't leak a half-built connection. `disconnect()`
      // is idempotent and best-effort.
      await disconnect();
      rethrow;
    }
  }

  Future<void> writeTx(List<int> bytes) {
    final tx = _tx;
    if (tx == null) throw StateError('BleConnection is not connected');
    return tx.write(bytes, withoutResponse: true);
  }

  Future<int?> readBatteryLevel() async {
    final c = _batteryLevel;
    if (c == null) return null;
    final v = await c.read();
    return v.isEmpty ? null : v.first;
  }

  /// Idempotent + best-effort. Each step is independently guarded so a
  /// failure in one (e.g. the BLE adapter is in a bad state) still releases
  /// the rest. Calling [disconnect] twice, or before a successful [connect],
  /// is fine.
  Future<void> disconnect() async {
    if (_closed) return;
    _closed = true;
    try {
      await _rxSub?.cancel();
    } catch (_) {/* best-effort */}
    _rxSub = null;
    try {
      if (!_rxController.isClosed) await _rxController.close();
    } catch (_) {/* best-effort */}
    try {
      await device.disconnect();
    } catch (_) {/* best-effort */}
  }
}
