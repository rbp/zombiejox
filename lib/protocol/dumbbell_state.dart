import '../state/weights.dart' show kJaxJoxWeightCount;
import 'frame.dart';
import 'opcodes.dart';

/// `0xD1` byte 6 — the only value we treat as "motor active" is `0x0C`.
/// Everything else (`0x04` settled, `0x07` in a query reply, anything
/// else) is idle. See `docs/ble_protocol.md` §5.
const int _motorActive = 0x0C;

class DumbbellState {
  final int weightIndex;
  final bool motorActive;
  final int? batteryPct;

  /// Raw "unit" byte from the `0xD1` reply (frame byte 8). The original
  /// JaxJox app receives this value but never compares it to any
  /// constant — `ChangedManager` just forwards it through a logger — so
  /// the mapping had to be recovered on-device. **Confirmed:** `0x00`
  /// = lbs, `0x01` = kg; see [weightUnitFromRawByte] for the conversion
  /// to [WeightUnit] (returns null for any unexpected value so callers
  /// can treat "unknown" as "don't guess"). Null on states that didn't
  /// come from a `0xD1` frame — `0xD2` periodic broadcasts don't carry
  /// the unit byte.
  final int? unitRaw;

  const DumbbellState({
    required this.weightIndex,
    required this.motorActive,
    this.batteryPct,
    this.unitRaw,
  });

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DumbbellState &&
          other.weightIndex == weightIndex &&
          other.motorActive == motorActive &&
          other.batteryPct == batteryPct &&
          other.unitRaw == unitRaw;

  @override
  int get hashCode =>
      Object.hash(weightIndex, motorActive, batteryPct, unitRaw);
}

/// Apply a parsed RX frame to the running state. Returns null if the frame is
/// not state-bearing (e.g. set-weight ACK/NACK).
DumbbellState? applyFrame(DumbbellState? prev, ParsedFrame frame) {
  switch (frame.opcode) {
    case Opcodes.queryStatus: // 0xD1 — query reply or motor-state push
      if (frame.payload.length < 6) return prev;
      final idx = frame.payload[1];
      if (idx < 0 || idx >= kJaxJoxWeightCount) return prev;
      // Payload offset 5 = frame byte 8 = unit. See [DumbbellState.unitRaw].
      return (prev ?? const DumbbellState(weightIndex: 0, motorActive: false))
          .copyWith(
        weightIndex: idx,
        motorActive: frame.payload[3] == _motorActive,
        batteryPct: frame.payload[4],
        unitRaw: frame.payload[5],
      );
    case Opcodes.stateBroadcast: // 0xD2 — periodic ~1 Hz
      if (frame.payload.length < 9) return prev;
      final idx = frame.payload[8]; // payload offset 8 == frame byte 11
      if (idx < 0 || idx >= kJaxJoxWeightCount) return prev;
      // If `0xD2` arrives before the first `0xD1` reply (rare — `Dumbbell.
      // connect` sends a query first), we'd otherwise have to synthesize
      // a default state (`motorActive: false`, no battery, no unit) and
      // the UI would briefly show a confident "8 lbs / Idle" with no
      // unit awareness. Return prev (null) instead so the card stays
      // on "Connecting…" until the real `0xD1` lands.
      if (prev == null) return prev;
      return prev.copyWith(weightIndex: idx);
    default:
      return prev;
  }
}
