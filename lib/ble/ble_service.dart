import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_connection_state.dart';
import 'ble_transport.dart';
import 'device_ref.dart';
import 'uuids.dart';

/// Production [BleTransport] backed by `flutter_blue_plus`.
///
/// This is the only class above `lib/ble/` that knows about
/// `BluetoothDevice` / `BluetoothCharacteristic` / `BluetoothConnectionState`
/// — by design. The rest of the app sees only [BleTransport] and
/// [DeviceRef].
///
/// [disconnect] is idempotent and best-effort: callers can invoke it after
/// a successful [connect], after a failed one, or twice in a row without
/// special casing. [connect] cleans up after itself if it throws partway
/// through, so a caller's `try/catch` doesn't need to know what step the
/// failure happened on.
class BleConnection implements BleTransport {
  @override
  final DeviceRef device;

  final BluetoothDevice _bluetoothDevice;

  BluetoothCharacteristic? _tx;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _batteryLevel;

  StreamSubscription<List<int>>? _rxSub;
  final StreamController<List<int>> _rxController =
      StreamController.broadcast();
  bool _closed = false;

  @override
  Stream<List<int>> get rxStream => _rxController.stream;

  @override
  Stream<BleConnectionState> get connectionState =>
      _bluetoothDevice.connectionState.map(_mapConnectionState);

  BleConnection(this.device)
      : _bluetoothDevice =
            BluetoothDevice(remoteId: DeviceIdentifier(device.id));

  @override
  Future<void> connect() async {
    if (_closed) throw StateError('BleConnection is closed');
    try {
      // License.free per the flutter_blue_plus LICENSE: ZombieJox is GPLv3
      // open-source community software for orphaned hardware (see README), not
      // a commercial product. Revisit if distribution model changes.
      await _bluetoothDevice.connect(license: License.free, autoConnect: false);

      final services = await _bluetoothDevice.discoverServices();
      final svc = services.firstWhere(
        (s) => s.uuid.str.toLowerCase() == JaxJoxUuids.service,
        orElse: () => throw StateError(
            'JaxJox service not found on ${_bluetoothDevice.remoteId}'),
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

  @override
  Future<void> writeTx(List<int> bytes) {
    final tx = _tx;
    if (tx == null) throw StateError('BleConnection is not connected');
    return tx.write(bytes, withoutResponse: true);
  }

  @override
  Future<int?> readBatteryLevel() async {
    final c = _batteryLevel;
    if (c == null) return null;
    final v = await c.read();
    return v.isEmpty ? null : v.first;
  }

  @override
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
      await _bluetoothDevice.disconnect();
    } catch (_) {/* best-effort */}
  }

  static BleConnectionState _mapConnectionState(BluetoothConnectionState s) {
    switch (s) {
      case BluetoothConnectionState.connected:
        return BleConnectionState.connected;
      case BluetoothConnectionState.disconnected:
        return BleConnectionState.disconnected;
      // Forward-compat hedge: today `flutter_blue_plus` only emits the two
      // states above, but older versions also surfaced transient
      // `connecting` / `disconnecting`. If the plugin ever resurrects them,
      // collapse both into `connecting` — the UI only cares about "not yet
      // live" vs "live" vs "cleanly gone", and "in transition" rounds to
      // "not yet live".
      default:
        return BleConnectionState.connecting;
    }
  }
}
