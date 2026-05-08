import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/state/preferences.dart';
import 'package:zombiejox/state/weights.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('unit', () {
    test('first read defaults to a valid unit (locale-derived)', () async {
      final prefs = await Preferences.load();
      final unit = prefs.getUnit();
      // The locale default depends on the test host; we only assert it's a
      // valid value.
      expect([WeightUnit.lbs, WeightUnit.kg], contains(unit));
    });

    test('setUnit persists and is read back on next load', () async {
      {
        final prefs = await Preferences.load();
        await prefs.setUnit(WeightUnit.kg);
        expect(prefs.getUnit(), WeightUnit.kg);
      }
      // Re-load — should read the persisted value, not the locale default.
      {
        final prefs = await Preferences.load();
        expect(prefs.getUnit(), WeightUnit.kg);
      }
    });

    test('explicit override survives multiple set operations', () async {
      final prefs = await Preferences.load();
      await prefs.setUnit(WeightUnit.kg);
      await prefs.setUnit(WeightUnit.lbs);
      expect(prefs.getUnit(), WeightUnit.lbs);
    });

    test('unit ValueListenable fires on change, not on no-op set', () async {
      final prefs = await Preferences.load();
      final initial = prefs.getUnit();
      final other = initial == WeightUnit.lbs ? WeightUnit.kg : WeightUnit.lbs;

      var notifications = 0;
      void listener() => notifications++;
      prefs.unit.addListener(listener);

      // Setting to the same value should not fire.
      await prefs.setUnit(initial);
      expect(notifications, 0);

      // Setting to a different value fires once.
      await prefs.setUnit(other);
      expect(notifications, 1);
      expect(prefs.unit.value, other);

      // Setting back fires again.
      await prefs.setUnit(initial);
      expect(notifications, 2);

      prefs.unit.removeListener(listener);
    });

    test('getUnit() and unit.value agree', () async {
      final prefs = await Preferences.load();
      await prefs.setUnit(WeightUnit.kg);
      expect(prefs.getUnit(), prefs.unit.value);
    });
  });

  group('hasShownBluetoothRationale', () {
    test('defaults to false on a fresh install', () async {
      final prefs = await Preferences.load();
      expect(prefs.hasShownBluetoothRationale, isFalse);
    });

    test('flipped to true by markBluetoothRationaleShown and persists',
        () async {
      {
        final prefs = await Preferences.load();
        await prefs.markBluetoothRationaleShown();
        expect(prefs.hasShownBluetoothRationale, isTrue);
      }
      {
        final prefs = await Preferences.load();
        expect(prefs.hasShownBluetoothRationale, isTrue);
      }
    });
  });
}
