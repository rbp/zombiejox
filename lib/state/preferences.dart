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
  static const _keyRememberedDeviceIds = 'remembered_device_ids';

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

  /// Remote IDs of the dumbbells from the user's most recent successful
  /// "Connect (N)" tap on the scan screen. Used to skip the scan step on
  /// warm start — read by `ScanScreen._ensurePermissions` to decide
  /// whether to auto-navigate straight to ControlScreen. Empty before the
  /// first ever connect.
  ///
  /// We persist plain `remoteId.str` values rather than serialised
  /// `BluetoothDevice`s because `flutter_blue_plus` can rehydrate a
  /// device from just the id, and that's the only field that survives
  /// across runs anyway.
  List<String> get rememberedDeviceIds {
    return _prefs.getStringList(_keyRememberedDeviceIds) ?? const [];
  }

  Future<void> setRememberedDeviceIds(List<String> ids) async {
    await _prefs.setStringList(_keyRememberedDeviceIds, ids);
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
