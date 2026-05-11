import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_service.dart';
import '../protocol/dumbbell_state.dart';
import '../protocol/frame.dart';
import '../protocol/opcodes.dart';

/// Drives a single DumbbellConnect (`DB200`) device.
///
/// Lifecycle: [connect] → use → [disconnect]. `disconnect()` may be called at
/// any point — including *during* an in-flight `connect()` (e.g. when the
/// containing screen disposes mid-connect). After `disconnect()`, all public
/// methods are no-ops and `isReady` is false. Idempotent.
class Dumbbell {
  final BleConnection _ble;
  final BluetoothDevice device;

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  Stream<DumbbellState> get states => _states.stream;

  DumbbellState? _last;
  DumbbellState? get lastState => _last;

  /// Set to `true` by [disconnect]. Once true, [connect] / [setWeightIndex] /
  /// [_onBytes] short-circuit so a teardown that races against an in-flight
  /// `connect()` cleans up gracefully without throwing on a closed stream or
  /// writing to a torn-down characteristic.
  bool _disposed = false;

  /// True once the dumbbell has reported any state AND has not been
  /// disconnected. Implies `connect()`'s `_ble.connect()` step finished
  /// successfully (TX/RX characteristics are initialized) AND we've received
  /// either the post-connect battery read or at least one `0xD2`/`0xD1`
  /// notification. Use this to gate `setWeightIndex()` calls — calling it
  /// before this is true would hit a `LateInitializationError` on the
  /// underlying TX characteristic.
  ///
  /// Reads via the public [lastState] getter so subclasses (test fakes) that
  /// override it are honoured.
  bool get isReady => !_disposed && lastState != null;

  Stream<BluetoothConnectionState> get connectionState => _ble.connectionState;

  StreamSubscription<List<int>>? _rxSub;

  Dumbbell(this.device) : _ble = BleConnection(device);

  Future<void> connect() async {
    if (_disposed) return;
    await _ble.connect();
    if (_disposed) {
      // disconnect() ran while _ble.connect() was in flight. Tear down what
      // we just brought up so we don't leave a connected device behind.
      try {
        await _ble.disconnect();
      } catch (_) {/* best-effort */}
      return;
    }
    _rxSub = _ble.rxStream.listen(_onBytes);
    await _ble.writeTx(buildFrame(Opcodes.queryStatus, const []));
    if (_disposed) return;
    final battery = await _ble.readBatteryLevel();
    if (_disposed) return;
    if (battery != null && !_states.isClosed) {
      _last = (_last ?? const DumbbellState(weightIndex: 0, motorActive: false))
          .copyWith(batteryPct: battery);
      _states.add(_last!);
    }
  }

  Future<void> setWeightIndex(int index) {
    assert(index >= 0 && index < 8, 'weight index must be 0..7');
    if (_disposed) return Future.value();
    return _ble.writeTx(buildFrame(Opcodes.setWeight, [index]));
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    _disposed = true;
    // Each step is best-effort: even if a previous one threw (e.g. the BLE
    // adapter is in a bad state) we still want to release everything else.
    try {
      await _rxSub?.cancel();
    } catch (_) {/* best-effort */}
    _rxSub = null;
    try {
      await _ble.disconnect();
    } catch (_) {/* best-effort */}
    try {
      if (!_states.isClosed) await _states.close();
    } catch (_) {/* best-effort */}
  }

  void _onBytes(List<int> bytes) {
    if (_disposed) return;
    final frame = parseFrame(bytes);
    if (frame == null) return;
    final prevUnit = _last?.unitRaw;
    final next = applyFrame(_last, frame);
    if (next != null && !_states.isClosed) {
      _last = next;
      _states.add(next);
      // One-shot probe: surface the dock's "unit" byte the first time we
      // see it for this device, and again whenever it changes. The
      // mapping (which value == lbs vs kg) isn't in the original APK —
      // the Java code receives the byte but never compares it to a
      // constant — so on-device observation is the only way to nail it
      // down. Flip the physical kg/lbs button on the dock and watch the
      // log to confirm.
      if (next.unitRaw != null && next.unitRaw != prevUnit) {
        debugPrint(
          '[dumbbell ${device.remoteId.str}] '
          '0xD1 unit byte = 0x${next.unitRaw!.toRadixString(16).padLeft(2, '0')} '
          '(${next.unitRaw})',
        );
      }
    }
  }
}
