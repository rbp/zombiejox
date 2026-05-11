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

  group('rememberedDeviceIds', () {
    test('defaults to empty before any set', () async {
      final prefs = await Preferences.load();
      expect(prefs.rememberedDeviceIds, isEmpty);
    });

    test('setRememberedDeviceIds persists across loads', () async {
      {
        final prefs = await Preferences.load();
        await prefs.setRememberedDeviceIds(['AA:01', 'AA:02']);
        expect(prefs.rememberedDeviceIds, ['AA:01', 'AA:02']);
      }
      {
        final prefs = await Preferences.load();
        expect(prefs.rememberedDeviceIds, ['AA:01', 'AA:02']);
      }
    });

    test('setRememberedDeviceIds([]) clears the list', () async {
      final prefs = await Preferences.load();
      await prefs.setRememberedDeviceIds(['AA:01']);
      await prefs.setRememberedDeviceIds(const []);
      expect(prefs.rememberedDeviceIds, isEmpty);
    });

    test('order is preserved (so the scan screen can pin them in tap order)',
        () async {
      final prefs = await Preferences.load();
      await prefs.setRememberedDeviceIds(['AA:03', 'AA:01', 'AA:02']);
      expect(prefs.rememberedDeviceIds, ['AA:03', 'AA:01', 'AA:02']);
    });

    test('setRememberedDeviceIds replaces, does not merge', () async {
      final prefs = await Preferences.load();
      await prefs.setRememberedDeviceIds(['AA:01', 'AA:02']);
      await prefs.setRememberedDeviceIds(['BB:01']);
      expect(prefs.rememberedDeviceIds, ['BB:01']);
    });
  });
}
