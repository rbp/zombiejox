import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_service.dart';
import '../protocol/dumbbell_state.dart';
import '../protocol/frame.dart';
import '../protocol/opcodes.dart';

/// Drives a single DumbbellConnect (`DB200`) device.
class Dumbbell {
  final BleConnection _ble;
  final BluetoothDevice device;

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  Stream<DumbbellState> get states => _states.stream;

  DumbbellState? _last;
  DumbbellState? get lastState => _last;

  Stream<BluetoothConnectionState> get connectionState => _ble.connectionState;

  StreamSubscription<List<int>>? _rxSub;

  Dumbbell(this.device) : _ble = BleConnection(device);

  Future<void> connect() async {
    await _ble.connect();
    _rxSub = _ble.rxStream.listen(_onBytes);
    await _ble.writeTx(buildFrame(Opcodes.queryStatus, const []));
    final battery = await _ble.readBatteryLevel();
    if (battery != null) {
      _last = (_last ?? const DumbbellState(weightIndex: 0, motorActive: false))
          .copyWith(batteryPct: battery);
      _states.add(_last!);
    }
  }

  Future<void> setWeightIndex(int index) {
    assert(index >= 0 && index < 8, 'weight index must be 0..7');
    return _ble.writeTx(buildFrame(Opcodes.setWeight, [index]));
  }

  Future<void> disconnect() async {
    await _rxSub?.cancel();
    _rxSub = null;
    await _ble.disconnect();
    await _states.close();
  }

  void _onBytes(List<int> bytes) {
    final frame = parseFrame(bytes);
    if (frame == null) return;
    final next = applyFrame(_last, frame);
    if (next != null) {
      _last = next;
      _states.add(next);
    }
  }
}
