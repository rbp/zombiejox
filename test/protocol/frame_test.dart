import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/protocol/dumbbell_state.dart';
import 'package:zombiejox/protocol/frame.dart';
import 'package:zombiejox/protocol/opcodes.dart';
import 'package:zombiejox/state/weights.dart';

void main() {
  group('buildFrame', () {
    test('all eight 0xD6 set-weight golden vectors (docs §4)', () {
      const golden = [
        [0xFF, 0x05, 0xD6, 0x00, 0x1C],
        [0xFF, 0x05, 0xD6, 0x01, 0x1F],
        [0xFF, 0x05, 0xD6, 0x02, 0x1E],
        [0xFF, 0x05, 0xD6, 0x03, 0x19],
        [0xFF, 0x05, 0xD6, 0x04, 0x18],
        [0xFF, 0x05, 0xD6, 0x05, 0x1B],
        [0xFF, 0x05, 0xD6, 0x06, 0x1A],
        [0xFF, 0x05, 0xD6, 0x07, 0x25],
      ];
      for (var i = 0; i < golden.length; i++) {
        expect(buildFrame(Opcodes.setWeight, [i]), golden[i]);
      }
    });

    test('query-status frame is FF 04 D1 16', () {
      expect(
          buildFrame(Opcodes.queryStatus, const []), [0xFF, 0x04, 0xD1, 0x16]);
    });
  });

  group('parseFrame', () {
    test('round-trips a built frame', () {
      final bytes = buildFrame(Opcodes.setWeight, [3]);
      final parsed = parseFrame(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.opcode, 0xD6);
      expect(parsed.payload, [3]);
    });

    test('rejects bad checksum', () {
      expect(parseFrame([0xFF, 0x05, 0xD6, 0x03, 0x00]), isNull);
    });

    test('rejects bad length', () {
      expect(parseFrame([0xFF, 0x99, 0xD6, 0x03, 0x19]), isNull);
    });

    test('rejects missing leading 0xFF', () {
      expect(parseFrame([0x00, 0x05, 0xD6, 0x03, 0x19]), isNull);
    });
  });

  group('applyFrame / DumbbellState', () {
    test('decodes a settled motor-state push (docs §5)', () {
      final frame = parseFrame(
          [0xFF, 0x0A, 0xD1, 0x00, 0x03, 0x64, 0x04, 0x64, 0x00, 0x6D]);
      expect(frame, isNotNull);
      final s = applyFrame(null, frame!);
      expect(s, isNotNull);
      expect(s!.weightIndex, 3);
      expect(kWeightLbsByIndex[s.weightIndex], 26);
      expect(s.motorActive, false);
      expect(s.batteryPct, 100);
    });

    test('decodes a motor-active push', () {
      final frame = parseFrame(
          [0xFF, 0x0A, 0xD1, 0x00, 0x03, 0x64, 0x0C, 0x64, 0x00, 0x75]);
      final s = applyFrame(null, frame!);
      expect(s!.motorActive, true);
    });

    test('0xD1 reply carries the raw unit byte from offset 8', () {
      // FF 0A D1 00 03 64 04 64 00 6D — the docs §5 motor-settle push,
      // unit byte at offset 8 is 0x00. The decompiled APK never assigns
      // a meaning to this byte, so we surface it as a raw int and let
      // the UI / on-device probe map it to lbs/kg.
      final frame = parseFrame(
          [0xFF, 0x0A, 0xD1, 0x00, 0x03, 0x64, 0x04, 0x64, 0x00, 0x6D]);
      final s = applyFrame(null, frame!);
      expect(s!.unitRaw, 0x00);
    });

    test('0xD2 broadcasts do not carry a unit byte — preserve the prior one',
        () {
      // 0xD2's byte layout (per ChangedManager.U0 log) has no unit field;
      // applying a 0xD2 to a state that already has unitRaw should leave
      // unitRaw alone.
      final d1 = parseFrame(
          [0xFF, 0x0A, 0xD1, 0x00, 0x03, 0x64, 0x04, 0x64, 0x01, 0x6C]);
      final afterD1 = applyFrame(null, d1!)!;
      expect(afterD1.unitRaw, 0x01);

      final d2 = parseFrame([
        0xFF, 0x10, 0xD2, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x20
      ]);
      final afterD2 = applyFrame(afterD1, d2!)!;
      expect(afterD2.weightIndex, 5);
      expect(afterD2.unitRaw, 0x01, reason: 'unitRaw must survive a 0xD2');
    });

    test('0xD2 broadcast updates weight index (docs §5)', () {
      final frame = parseFrame([
        0xFF,
        0x10,
        0xD2,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x24
      ]);
      final s = applyFrame(null, frame!);
      expect(s!.weightIndex, 1);
      expect(kWeightLbsByIndex[s.weightIndex], 14);
    });
  });
}
