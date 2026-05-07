import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

import 'weights.dart';

/// Persisted user preferences. Backed by `shared_preferences`; safe to call
/// before any UI is built.
class Preferences {
  Preferences._(this._prefs);

  final SharedPreferences _prefs;

  static const _keyUnit = 'units';

  static Future<Preferences> load() async {
    final p = await SharedPreferences.getInstance();
    return Preferences._(p);
  }

  /// User-selected display unit. Defaults to lbs in US/UK locales, kg
  /// elsewhere; overridable via [setUnit]. The setting only affects what the
  /// app shows — the dumbbell's physical display follows its own setting.
  WeightUnit getUnit() {
    final raw = _prefs.getString(_keyUnit);
    if (raw != null) return WeightUnit.fromName(raw);
    return _localeDefaultUnit();
  }

  Future<void> setUnit(WeightUnit unit) async {
    await _prefs.setString(_keyUnit, unit.name);
  }
}

WeightUnit _localeDefaultUnit() {
  // Countries that still routinely quote bodyweight / dumbbell weight in lbs:
  // US, UK (mixed in practice but lbs for fitness), Liberia, Myanmar.
  // Default to kg everywhere else.
  const lbsCountries = {'US', 'GB', 'LR', 'MM'};
  final country = PlatformDispatcher.instance.locale.countryCode?.toUpperCase();
  if (country != null && lbsCountries.contains(country)) {
    return WeightUnit.lbs;
  }
  return WeightUnit.kg;
}
