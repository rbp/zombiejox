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
      final unit = prefs.unit.value;
      // The locale default depends on the test host; we only assert it's a
      // valid value.
      expect([WeightUnit.lbs, WeightUnit.kg], contains(unit));
    });

    test('setUnit persists and is read back on next load', () async {
      {
        final prefs = await Preferences.load();
        await prefs.setUnit(WeightUnit.kg);
        expect(prefs.unit.value, WeightUnit.kg);
      }
      // Re-load — should read the persisted value, not the locale default.
      {
        final prefs = await Preferences.load();
        expect(prefs.unit.value, WeightUnit.kg);
      }
    });

    test('explicit override survives multiple set operations', () async {
      final prefs = await Preferences.load();
      await prefs.setUnit(WeightUnit.kg);
      await prefs.setUnit(WeightUnit.lbs);
      expect(prefs.unit.value, WeightUnit.lbs);
    });

    test('unit ValueListenable fires on change, not on no-op set', () async {
      final prefs = await Preferences.load();
      final initial = prefs.unit.value;
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

  group('customDeviceNames', () {
    test('defaults to empty before any set', () async {
      final prefs = await Preferences.load();
      expect(prefs.customDeviceNames, isEmpty);
    });

    test('setCustomDeviceNames persists across loads', () async {
      {
        final prefs = await Preferences.load();
        await prefs.setCustomDeviceNames({
          'AA:01': 'Left',
          'AA:02': 'Right',
        });
        expect(prefs.customDeviceNames, {
          'AA:01': 'Left',
          'AA:02': 'Right',
        });
      }
      {
        final prefs = await Preferences.load();
        expect(prefs.customDeviceNames, {
          'AA:01': 'Left',
          'AA:02': 'Right',
        });
      }
    });

    test('setCustomDeviceNames replaces, does not merge', () async {
      final prefs = await Preferences.load();
      await prefs.setCustomDeviceNames({'AA:01': 'Left'});
      await prefs.setCustomDeviceNames({'AA:02': 'Right'});
      expect(prefs.customDeviceNames, {'AA:02': 'Right'});
    });

    test('setCustomDeviceNames({}) clears the stored value', () async {
      final prefs = await Preferences.load();
      await prefs.setCustomDeviceNames({'AA:01': 'Left'});
      await prefs.setCustomDeviceNames(const {});
      expect(prefs.customDeviceNames, isEmpty);
    });

    test('malformed payload on disk is treated as empty (no crash on launch)',
        () async {
      // Simulate a corrupted preference value — manual edit, schema
      // shift, etc. The user's fitness app shouldn't refuse to start
      // because of one bad pref.
      SharedPreferences.setMockInitialValues({
        'custom_device_names': '{not valid json',
      });
      final prefs = await Preferences.load();
      expect(prefs.customDeviceNames, isEmpty);
    });

    test(
        'payload with non-string values is treated as empty (defensive '
        'against a future schema change)', () async {
      SharedPreferences.setMockInitialValues({
        'custom_device_names': '{"AA:01": 42}',
      });
      final prefs = await Preferences.load();
      expect(prefs.customDeviceNames, isEmpty);
    });
  });

  group('unitExplicitlyChosen', () {
    test('defaults to false on a fresh install', () async {
      final prefs = await Preferences.load();
      expect(prefs.unitExplicitlyChosen, isFalse);
    });

    test('setUnit flips the flag to true and it persists across loads',
        () async {
      {
        final prefs = await Preferences.load();
        await prefs.setUnit(WeightUnit.kg);
        expect(prefs.unitExplicitlyChosen, isTrue);
      }
      {
        final prefs = await Preferences.load();
        expect(prefs.unitExplicitlyChosen, isTrue);
      }
    });

    test('setUnit flips the flag even when called with the current value',
        () async {
      // A user opening Settings, looking at the toggle, and tapping the
      // already-selected option still counts as an explicit choice.
      final prefs = await Preferences.load();
      final current = prefs.unit.value;
      await prefs.setUnit(current);
      expect(prefs.unitExplicitlyChosen, isTrue);
    });

    test(
        'setUnit persists the unit string even when value matches the '
        'in-memory default — so a locale change after the user re-taps '
        'cannot override their explicit choice', () async {
      // Fresh install: 'units' key is absent, in-memory value comes from
      // the locale. The user opens Settings, taps the already-selected
      // option — that's still an explicit pick.
      final prefs = await Preferences.load();
      final picked = prefs.unit.value;
      await prefs.setUnit(picked);

      // Simulate a re-launch where the locale now disagrees with the
      // user's pick. We can't move the locale itself in a unit test,
      // but reloading Preferences and checking the persisted value is
      // what would happen — if `_keyUnit` was persisted on the no-op
      // path, the reload reads it instead of falling back to the
      // locale derivation.
      final reloaded = await Preferences.load();
      expect(reloaded.unit.value, picked,
          reason: 'an explicit re-tap of the current value must still persist '
              "the unit string so a later locale shift can't override it");
      expect(reloaded.unitExplicitlyChosen, isTrue);
    });

    test(
        'setUnitIfNotExplicit changes the value and returns true when '
        'the flag is false', () async {
      final prefs = await Preferences.load();
      final initial = prefs.unit.value;
      final other = initial == WeightUnit.lbs ? WeightUnit.kg : WeightUnit.lbs;

      final changed = await prefs.setUnitIfNotExplicit(other);
      expect(changed, isTrue);
      expect(prefs.unit.value, other);
      // Auto-matching does NOT mark the unit as explicitly chosen — a
      // later auto-match (or the user opening Settings) is still allowed
      // to fire.
      expect(prefs.unitExplicitlyChosen, isFalse);
    });

    test('setUnitIfNotExplicit returns false when the value already matches',
        () async {
      final prefs = await Preferences.load();
      final current = prefs.unit.value;
      final changed = await prefs.setUnitIfNotExplicit(current);
      expect(changed, isFalse);
    });

    test('setUnitIfNotExplicit is a no-op once the user has chosen', () async {
      final prefs = await Preferences.load();
      await prefs.setUnit(WeightUnit.lbs);
      expect(prefs.unitExplicitlyChosen, isTrue);

      final changed = await prefs.setUnitIfNotExplicit(WeightUnit.kg);
      expect(changed, isFalse);
      expect(prefs.unit.value, WeightUnit.lbs,
          reason: 'explicit choice must not be overridden by auto-match');
    });
  });
}
