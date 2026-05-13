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
///
/// **Reconnect path** (post-§2a): when the underlying transport drops
/// mid-session (the device went out of range, lost power, etc.), the
/// owner ([WeightGroup]) calls [handleTransportDrop] to clear stale
/// per-connect state and then [reconnect] to build a fresh
/// [BleConnection] for the same [DeviceRef]. The `Dumbbell` instance
/// survives across the drop — its identity, its `states` / `connectionState`
/// stream subscribers, and its place in the group's membership are
/// unchanged. `connectionState` is proxied through a Dumbbell-owned
/// broadcast controller so subscribers stay attached across the
/// underlying transport swap.
class Dumbbell {
  /// Non-final because [reconnect] swaps in a fresh [BleConnection] for the
  /// same [DeviceRef] after a transport drop. The swap is internal —
  /// subscribers to [connectionState] / [states] are unaffected.
  BleTransport _ble;
  final DeviceRef device;

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  Stream<DumbbellState> get states => _states.stream;

  /// Proxies the current [_ble.connectionState] through a Dumbbell-owned
  /// broadcast so subscribers (today: `DumbbellCard`, `WeightGroup`) stay
  /// attached across a [reconnect] transport swap. The forwarder is wired
  /// lazily via `onListen` so test fakes (which override
  /// [connectionState] entirely) never trigger the platform-channel
  /// subscription on [_ble.connectionState] — `flutter_blue_plus` throws
  /// `UnsupportedOperation` outside a real Android / iOS host.
  late final StreamController<BleConnectionState> _connStateController =
      StreamController<BleConnectionState>.broadcast(
    onListen: _wireConnForwarder,
    onCancel: _unwireConnForwarder,
  );
  StreamSubscription<BleConnectionState>? _connFwd;

  DumbbellState? _last;
  DumbbellState? get lastState => _last;

  /// Battery percentage read from the standard BLE Battery Service during
  /// [connect], stashed here until the first real `0xD1`/`0xD2` arrives
  /// — at which point [_onBytes] folds it into the emitted state and
  /// clears it. The alternative (fabricating a synthetic `DumbbellState`
  /// from a battery byte alone) would flip [isReady] true before any
  /// unit byte has been observed, which downstream auto-match logic
  /// (`UnitAutoMatcher` via `HomeScreen`) would then have to work
  /// around. Keep the asymmetry here, not in the consumer.
  int? _pendingBatteryPct;

  /// Set to `true` by [disconnect]. Once true, [connect] / [setWeightIndex] /
  /// [_onBytes] / [handleTransportDrop] / [reconnect] short-circuit so a
  /// teardown that races against an in-flight connect or reconnect cleans
  /// up gracefully without throwing on a closed stream or writing to a
  /// torn-down characteristic.
  bool _disposed = false;

  /// True once the dumbbell has reported a real `0xD1` / `0xD2` state
  /// frame AND has not been disconnected. Implies `connect()`'s
  /// `_ble.connect()` step finished successfully (TX/RX characteristics
  /// are initialized) AND the device has sent at least one state
  /// notification — i.e. it's responsive on the protocol channel, not
  /// just connected at the BLE level. Use this to gate
  /// `setWeightIndex()` calls.
  ///
  /// Goes back to `false` after [handleTransportDrop] clears [lastState]
  /// — a dropped-then-reconnecting dumbbell is not ready until the new
  /// connection emits its first state frame.
  bool get isReady => !_disposed && lastState != null;

  Stream<BleConnectionState> get connectionState => _connStateController.stream;

  StreamSubscription<List<int>>? _rxSub;

  /// Constructs a [Dumbbell] driven by the production [BleConnection].
  /// Tests that need a transport seam should subclass [Dumbbell] directly
  /// (see `FakeDumbbell` in `test/devices/weight_group_test.dart`).
  Dumbbell(this.device) : _ble = BleConnection(device);

  /// Subscribes to whichever [_ble] is current and pumps its
  /// [BleTransport.connectionState] events into [_connStateController].
  /// Wired by the controller's `onListen` callback and re-run after a
  /// [reconnect] transport swap so subscribers keep seeing live events.
  void _wireConnForwarder() {
    final old = _connFwd;
    if (old != null) unawaited(old.cancel());
    _connFwd = _ble.connectionState.listen((s) {
      if (_connStateController.isClosed) return;
      _connStateController.add(s);
    });
  }

  void _unwireConnForwarder() {
    final old = _connFwd;
    _connFwd = null;
    if (old != null) unawaited(old.cancel());
  }

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

  /// Called by the owning [WeightGroup] when the underlying transport
  /// reports a `disconnected` event after this dumbbell has previously
  /// been ready — i.e. a mid-session drop, not a graceful close.
  ///
  /// Clears the per-connect state ([lastState], stashed battery, the RX
  /// subscription bound to the now-invalidated characteristic) without
  /// flipping [_disposed]. After this call, [isReady] returns false and
  /// [reconnect] can re-establish the link on the same `Dumbbell`
  /// instance.
  ///
  /// **Internal-API**: only [WeightGroup]'s reconnect supervisor should
  /// invoke this. Calling it from outside the supervisor would surprise
  /// the supervisor's bookkeeping. Idempotent and safe to call on a
  /// disposed dumbbell (no-op).
  void handleTransportDrop() {
    if (_disposed) return;
    unawaited(_rxSub?.cancel() ?? Future<void>.value());
    _rxSub = null;
    _last = null;
    _pendingBatteryPct = null;
  }

  /// Tear down the current [_ble] and connect a fresh [BleConnection] to
  /// the same [DeviceRef]. Subscribers to [states] / [connectionState]
  /// stay attached — the controllers survive the swap.
  ///
  /// Must be paired with [handleTransportDrop] to clear per-connect
  /// state first; calling [reconnect] without it would leak the old
  /// RX subscription. **Internal-API**: invoked by [WeightGroup]'s
  /// retry supervisor; not part of the public lifecycle. No-op if
  /// already [_disposed].
  Future<void> reconnect() async {
    if (_disposed) return;
    final old = _ble;
    final hadListener = _connStateController.hasListener;
    try {
      await _connFwd?.cancel();
    } catch (_) {/* best-effort */}
    _connFwd = null;
    try {
      await old.disconnect();
    } catch (_) {/* best-effort */}
    if (_disposed) return;
    _ble = BleConnection(device);
    // Re-wire only if someone was listening before the swap — the
    // controller's `onListen` would otherwise wire on the next
    // subscription. Skipping the re-wire when there are no listeners
    // avoids gratuitously touching `flutter_blue_plus`'s platform
    // channel in tests that don't drive `connectionState`.
    if (hadListener) _wireConnForwarder();
    await connect();
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
    // Capture whether the conn-state controller has been initialized
    // BEFORE we null out _connFwd. _connFwd non-null implies
    // _wireConnForwarder ran, which only runs via the controller's
    // `onListen` — so the controller has been initialized. The `late
    // final` is otherwise lazy: fakes that override `connectionState`
    // never touch it, and we don't want to force a useless init here.
    final controllerInitialized = _connFwd != null;
    try {
      await _connFwd?.cancel();
    } catch (_) {/* best-effort */}
    _connFwd = null;
    try {
      await _ble.disconnect();
    } catch (_) {/* best-effort */}
    try {
      if (!_states.isClosed) await _states.close();
    } catch (_) {/* best-effort */}
    if (controllerInitialized) {
      try {
        if (!_connStateController.isClosed) {
          await _connStateController.close();
        }
      } catch (_) {/* best-effort */}
    }
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
