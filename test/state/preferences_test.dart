import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/state/preferences.dart';
import 'package:zombiejox/state/weights.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
}
