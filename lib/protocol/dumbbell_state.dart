import '../state/weights.dart';
import 'frame.dart';
import 'opcodes.dart';

/// `0xD1` byte 6 — motor active. `0x04` is "settled"; other values (e.g. `0x07`
/// in a query reply) mean the same thing for our purposes — not actively moving.
/// See `docs/ble_protocol.md` §5.
const int _motorActive = 0x0C;

class DumbbellState {
  final int weightIndex;
  final bool motorActive;
  final int? batteryPct;

  /// Raw "unit" byte from the `0xD1` reply (frame byte 8). The original
  /// JaxJox app receives this value but never compares it to any
  /// constant — `ChangedManager` just forwards it through a logger — so
  /// the `0 = lbs / 1 = kg` (or reverse) mapping isn't recoverable from
  /// the decompiled code and needs on-device confirmation. Once the
  /// mapping is known, ControlScreen can auto-match the app's display
  /// unit to the dock's. Null on states that didn't come from a `0xD1`
  /// frame — `0xD2` periodic broadcasts don't carry the unit byte.
  final int? unitRaw;

  const DumbbellState({
    required this.weightIndex,
    required this.motorActive,
    this.batteryPct,
    this.unitRaw,
  });

  /// Convenience: current weight in pounds. Use [formatWeight] from
  /// `state/weights.dart` if you need a unit-aware display string.
  int get weightLbs => kWeightLbsByIndex[weightIndex];

  DumbbellState copyWith({
    int? weightIndex,
    bool? motorActive,
    int? batteryPct,
    int? unitRaw,
  }) =>
      DumbbellState(
        weightIndex: weightIndex ?? this.weightIndex,
        motorActive: motorActive ?? this.motorActive,
        batteryPct: batteryPct ?? this.batteryPct,
        unitRaw: unitRaw ?? this.unitRaw,
      );
}

/// Apply a parsed RX frame to the running state. Returns null if the frame is
/// not state-bearing (e.g. set-weight ACK/NACK).
DumbbellState? applyFrame(DumbbellState? prev, ParsedFrame frame) {
  switch (frame.opcode) {
    case Opcodes.queryStatus: // 0xD1 — query reply or motor-state push
      if (frame.payload.length < 6) return prev;
      final idx = frame.payload[1];
      if (idx < 0 || idx >= kJaxJoxWeightCount) return prev;
      final motion = frame.payload[3];
      final battery = frame.payload[4];
      // Payload offset 5 = frame byte 8 = unit. See [DumbbellState.unitRaw].
      final unitRaw = frame.payload[5];
      return DumbbellState(
        weightIndex: idx,
        motorActive: motion == _motorActive,
        batteryPct: battery,
        unitRaw: unitRaw,
      );
    case Opcodes.stateBroadcast: // 0xD2 — periodic ~1 Hz
      if (frame.payload.length < 9) return prev;
      final idx = frame.payload[8]; // payload offset 8 == frame byte 11
      if (idx < 0 || idx >= kJaxJoxWeightCount) return prev;
      return (prev ?? const DumbbellState(weightIndex: 0, motorActive: false))
          .copyWith(weightIndex: idx);
    default:
      return prev;
  }
}
