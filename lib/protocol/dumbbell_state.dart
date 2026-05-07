import 'frame.dart';
import 'opcodes.dart';

/// 0–7 → published JaxJox weight steps in pounds. See `docs/ble_protocol.md` §4.
const List<int> kWeightLbsByIndex = [8, 14, 20, 26, 32, 38, 44, 50];

/// `0xD1` byte 6 — motor active. `0x04` is "settled"; other values (e.g. `0x07`
/// in a query reply) mean the same thing for our purposes — not actively moving.
/// See `docs/ble_protocol.md` §5.
const int _motorActive = 0x0C;

class DumbbellState {
  final int weightIndex;
  final bool motorActive;
  final int? batteryPct;

  const DumbbellState({
    required this.weightIndex,
    required this.motorActive,
    this.batteryPct,
  });

  int get weightLbs => kWeightLbsByIndex[weightIndex];

  DumbbellState copyWith({int? weightIndex, bool? motorActive, int? batteryPct}) =>
      DumbbellState(
        weightIndex: weightIndex ?? this.weightIndex,
        motorActive: motorActive ?? this.motorActive,
        batteryPct: batteryPct ?? this.batteryPct,
      );
}

/// Apply a parsed RX frame to the running state. Returns null if the frame is
/// not state-bearing (e.g. set-weight ACK/NACK).
DumbbellState? applyFrame(DumbbellState? prev, ParsedFrame frame) {
  switch (frame.opcode) {
    case Opcodes.queryStatus: // 0xD1 — query reply or motor-state push
      if (frame.payload.length < 6) return prev;
      final idx = frame.payload[1];
      if (idx < 0 || idx >= kWeightLbsByIndex.length) return prev;
      final motion = frame.payload[3];
      final battery = frame.payload[4];
      return DumbbellState(
        weightIndex: idx,
        motorActive: motion == _motorActive,
        batteryPct: battery,
      );
    case Opcodes.stateBroadcast: // 0xD2 — periodic ~1 Hz
      if (frame.payload.length < 9) return prev;
      final idx = frame.payload[8]; // payload offset 8 == frame byte 11
      if (idx < 0 || idx >= kWeightLbsByIndex.length) return prev;
      return (prev ?? const DumbbellState(weightIndex: 0, motorActive: false))
          .copyWith(weightIndex: idx);
    default:
      return prev;
  }
}
