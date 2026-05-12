import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/state/weights.dart';

void main() {
  group('weight tables', () {
    test('eight valid indices for DumbbellConnect', () {
      expect(kJaxJoxWeightCount, 8);
      expect(kWeightLbsByIndex.length, 8);
      expect(kWeightKgByIndex.length, 8);
    });

    test('lbs ladder matches docs/ble_protocol.md §2g', () {
      expect(kWeightLbsByIndex, [8, 14, 20, 26, 32, 38, 44, 50]);
    });

    test('kg ladder matches docs/ble_protocol.md §2g', () {
      // Index 6 is the dock-displayed `20`, not the exact lb→kg conversion
      // (`19.9`). On-device verified.
      expect(kWeightKgByIndex, [3.6, 6.4, 9.1, 11.8, 14.5, 17.2, 20.0, 22.7]);
    });

    test('lbs values are strictly increasing', () {
      for (var i = 1; i < kWeightLbsByIndex.length; i++) {
        expect(kWeightLbsByIndex[i], greaterThan(kWeightLbsByIndex[i - 1]));
      }
    });
  });

  group('formatWeight', () {
    test('lbs formatting', () {
      expect(formatWeight(0, WeightUnit.lbs), '8 lbs');
      expect(formatWeight(7, WeightUnit.lbs), '50 lbs');
    });

    test('kg formatting (one decimal place)', () {
      expect(formatWeight(0, WeightUnit.kg), '3.6 kg');
      expect(formatWeight(4, WeightUnit.kg), '14.5 kg');
      expect(formatWeight(7, WeightUnit.kg), '22.7 kg');
    });

    test('kg whole-number value renders without `.0` (matches dock display)', () {
      // Index 6 in kg mode shows as `20` on the dock, not `20.0`.
      expect(formatWeight(6, WeightUnit.kg), '20 kg');
    });

    test('out-of-range index returns empty string (UI safety)', () {
      expect(formatWeight(-1, WeightUnit.lbs), '');
      expect(formatWeight(8, WeightUnit.lbs), '');
      expect(formatWeight(99, WeightUnit.kg), '');
    });
  });

  group('WeightUnit', () {
    test('round-trips through name', () {
      expect(WeightUnit.fromName('lbs'), WeightUnit.lbs);
      expect(WeightUnit.fromName('kg'), WeightUnit.kg);
      expect(WeightUnit.fromName(WeightUnit.lbs.name), WeightUnit.lbs);
      expect(WeightUnit.fromName(WeightUnit.kg.name), WeightUnit.kg);
    });

    test('unknown / null defaults to lbs', () {
      expect(WeightUnit.fromName(null), WeightUnit.lbs);
      expect(WeightUnit.fromName('stones'), WeightUnit.lbs);
      expect(WeightUnit.fromName(''), WeightUnit.lbs);
    });
  });

  group('weightUnitFromRawByte', () {
    test('0x00 is lbs, 0x01 is kg (on-device-confirmed mapping)', () {
      expect(weightUnitFromRawByte(0x00), WeightUnit.lbs);
      expect(weightUnitFromRawByte(0x01), WeightUnit.kg);
    });

    test('null and unknown values return null, not a guess', () {
      // The unit byte is a small enum — anything other than 0/1 means
      // we got an unexpected value and shouldn't guess. The caller
      // treats null as "leave the app's display unit alone".
      expect(weightUnitFromRawByte(null), isNull);
      expect(weightUnitFromRawByte(2), isNull);
      expect(weightUnitFromRawByte(0xFF), isNull);
      expect(weightUnitFromRawByte(-1), isNull);
    });
  });
}
