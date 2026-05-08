import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import 'weights.dart';

/// Persisted user preferences. Backed by `shared_preferences`; safe to call
/// before any UI is built.
///
/// The current value of every preference is exposed as a [ValueListenable]
/// so widgets can rebuild reactively (e.g. flipping the lbs/kg toggle in
/// settings re-labels weight buttons across every visible screen without a
/// navigation round-trip).
class Preferences {
  Preferences._(this._prefs)
      : _unit = ValueNotifier<WeightUnit>(_initialUnit(_prefs));

  final SharedPreferences _prefs;
  final ValueNotifier<WeightUnit> _unit;

  static const _keyUnit = 'units';
  static const _keyBluetoothRationaleShown = 'bluetooth_rationale_shown';

  static Future<Preferences> load() async {
    final p = await SharedPreferences.getInstance();
    return Preferences._(p);
  }

  /// User-selected display unit. Defaults to lbs in US/UK/LR/MM locales, kg
  /// elsewhere; overridable via [setUnit]. The setting only affects what the
  /// app shows — the dumbbell's physical display follows its own setting.
  ValueListenable<WeightUnit> get unit => _unit;

  /// Current value (synchronous read). Equivalent to `unit.value`.
  WeightUnit getUnit() => _unit.value;

  Future<void> setUnit(WeightUnit unit) async {
    if (_unit.value == unit) return;
    _unit.value = unit;
    await _prefs.setString(_keyUnit, unit.name);
  }

  /// True once the user has been shown (and dismissed) the pre-permission
  /// rationale screen. Used by [main] to skip the rationale on subsequent
  /// launches — first impression is what matters there. If the user later
  /// revokes the permission, the scan screen has its own re-grant flow.
  bool get hasShownBluetoothRationale =>
      _prefs.getBool(_keyBluetoothRationaleShown) ?? false;

  Future<void> markBluetoothRationaleShown() async {
    await _prefs.setBool(_keyBluetoothRationaleShown, true);
  }
}

WeightUnit _initialUnit(SharedPreferences prefs) {
  final raw = prefs.getString(Preferences._keyUnit);
  if (raw != null) return WeightUnit.fromName(raw);
  return _localeDefaultUnit();
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
