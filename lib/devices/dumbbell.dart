import 'dart:async';

import '../ble/ble_connection_state.dart';
import '../ble/ble_service.dart';
import '../ble/ble_transport.dart';
import '../ble/device_ref.dart';
import '../protocol/dumbbell_state.dart';
import '../protocol/frame.dart';
import '../protocol/opcodes.dart';
import '../state/weights.dart' show kJaxJoxWeightCount;

/// Drives a single DumbbellConnect (`DB200`) device.
///
/// Lifecycle: [connect] → use → [disconnect]. `disconnect()` may be called at
/// any point — including *during* an in-flight `connect()` (e.g. when the
/// containing screen disposes mid-connect). After `disconnect()`, all public
/// methods are no-ops and `isReady` is false. Idempotent.
class Dumbbell {
  final BleTransport _ble;
  final DeviceRef device;

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  Stream<DumbbellState> get states => _states.stream;

  DumbbellState? _last;
  DumbbellState? get lastState => _last;

  /// Battery percentage read from the standard BLE Battery Service during
  /// [connect], stashed here until the first real `0xD1`/`0xD2` arrives
  /// — at which point [_onBytes] folds it into the emitted state and
  /// clears it. The alternative (fabricating a synthetic `DumbbellState`
  /// from a battery byte alone) would flip [isReady] true before any
  /// unit byte has been observed, which downstream auto-match logic
  /// (`UnitAutoMatcher` via `ControlScreen`) would then have to work
  /// around. Keep the asymmetry here, not in the consumer.
  int? _pendingBatteryPct;

  /// Set to `true` by [disconnect]. Once true, [connect] / [setWeightIndex] /
  /// [_onBytes] short-circuit so a teardown that races against an in-flight
  /// `connect()` cleans up gracefully without throwing on a closed stream or
  /// writing to a torn-down characteristic.
  bool _disposed = false;

  /// True once the dumbbell has reported a real `0xD1` / `0xD2` state
  /// frame AND has not been disconnected. Implies `connect()`'s
  /// `_ble.connect()` step finished successfully (TX/RX characteristics
  /// are initialized) AND the device has sent at least one state
  /// notification — i.e. it's responsive on the protocol channel, not
  /// just connected at the BLE level. Use this to gate
  /// `setWeightIndex()` calls.
  ///
  /// Reads via the public [lastState] getter so subclasses (test fakes) that
  /// override it are honoured.
  bool get isReady => !_disposed && lastState != null;

  Stream<BleConnectionState> get connectionState => _ble.connectionState;

  StreamSubscription<List<int>>? _rxSub;

  /// Constructs a [Dumbbell] driven by the production [BleConnection].
  /// Tests that need a transport seam should subclass [Dumbbell] directly
  /// (see `FakeDumbbell` in `test/devices/weight_group_test.dart`).
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
    if (battery == null) return;
    if (_last != null && !_states.isClosed) {
      // A `0xD1` or `0xD2` already arrived — fold the battery byte into
      // the existing state and emit.
      _last = _last!.copyWith(batteryPct: battery);
      _states.add(_last!);
    } else {
      // No state frame yet — stash for `_onBytes` to merge in.
      _pendingBatteryPct = battery;
    }
  }

  Future<void> setWeightIndex(int index) {
    // Real `RangeError`, not an `assert` — out-of-range payloads to a piece
    // of motorised hardware shouldn't be a debug-only guard. `0x27` (in
    // the protocol doc) is the canonical example of what can go wrong
    // when a bad write reaches the dock; out-of-range `0xD6` is in the
    // same caution class.
    if (index < 0 || index >= kJaxJoxWeightCount) {
      throw RangeError.range(index, 0, kJaxJoxWeightCount - 1, 'index');
    }
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
    var next = applyFrame(_last, frame);
    if (next == null || _states.isClosed) return;
    // Fold a pending battery read into the first emitted state, then
    // clear the stash so a stale value can't outlive the connection.
    // Battery Service wins over the 0xD1 payload byte — mirrors the
    // connect-path override at the `_last != null` branch above, which
    // picks one source consistently.
    if (_pendingBatteryPct != null) {
      next = next.copyWith(batteryPct: _pendingBatteryPct);
      _pendingBatteryPct = null;
    }
    _last = next;
    _states.add(next);
  }
}
