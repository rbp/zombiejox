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
  static const _keyUnitExplicit = 'unit_explicitly_chosen';
  static const _keyRememberedDeviceIds = 'remembered_device_ids';

  static Future<Preferences> load() async {
    final p = await SharedPreferences.getInstance();
    return Preferences._(p);
  }

  /// User-selected display unit. Defaults to lbs in US/UK/LR/MM locales, kg
  /// elsewhere; overridable via [setUnit]. The setting only affects what the
  /// app shows — the dumbbell's physical display follows its own setting.
  ///
  /// Read the synchronous current value via `preferences.unit.value`.
  ValueListenable<WeightUnit> get unit => _unit;

  /// Whether the user has *explicitly* picked a unit via the Settings
  /// toggle (vs. the value still being the locale-derived default or an
  /// auto-match from the dock). Once true, the auto-match-from-dock UX in
  /// [ControlScreen] becomes a no-op. Persists across launches.
  bool get unitExplicitlyChosen => _prefs.getBool(_keyUnitExplicit) ?? false;

  /// User-facing setter — flips [unitExplicitlyChosen] to true regardless
  /// of whether the value actually changed (the user tapped the toggle;
  /// even a re-tap of the current value counts as an explicit choice).
  ///
  /// Always persists the unit string too, even if it equals the current
  /// in-memory value — otherwise an explicit re-tap on a fresh install
  /// (where `_keyUnit` is still unset) would leave `_keyUnit` unset and
  /// a future launch in a different locale could re-derive a unit that
  /// disagrees with the user's choice.
  Future<void> setUnit(WeightUnit unit) async {
    await _prefs.setBool(_keyUnitExplicit, true);
    await _prefs.setString(_keyUnit, unit.name);
    if (_unit.value == unit) return;
    _unit.value = unit;
  }

  /// Auto-match setter — used by ControlScreen when all connected
  /// dumbbells agree on a unit and the user hasn't picked one yet. No-op
  /// if [unitExplicitlyChosen] is already true, or if the current value
  /// already matches. Returns true iff the persisted value actually
  /// changed (lets the caller decide whether to surface a SnackBar).
  Future<bool> setUnitIfNotExplicit(WeightUnit unit) async {
    if (unitExplicitlyChosen) return false;
    if (_unit.value == unit) return false;
    _unit.value = unit;
    await _prefs.setString(_keyUnit, unit.name);
    return true;
  }

  /// Remote IDs of the dumbbells from the user's most recent *verified*
  /// successful connect — written only after at least one member of the
  /// connected group reaches `Dumbbell.isReady` (via the `onAnyConnected`
  /// callback ScanScreen hooks into ControlScreen). A Connect-tap that
  /// fails on every device never updates this list, so warm-start
  /// auto-navigation always tries to reconnect to a set that has worked
  /// at least once before. Used to skip the scan step on warm start —
  /// read by `ScanScreen._ensurePermissions` to decide whether to
  /// auto-navigate straight to ControlScreen. Empty before the first
  /// verified successful connect.
  ///
  /// We persist plain id strings rather than serialised `DeviceRef`s —
  /// the id is the only field that survives across runs anyway, and any
  /// BLE adapter can rehydrate a peripheral handle from just the id.
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
