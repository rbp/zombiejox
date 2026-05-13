import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../ble/device_ref.dart';
import 'preferences.dart';

/// Per-`DeviceRef` user-owned metadata for a single selected dumbbell.
///
/// Today: the device handle and an optional custom display name (§2e).
/// Designed to grow into a per-device weight override (§2f) — the
/// per-device override and the custom name share the same lifecycle
/// (created when a device is selected, modified by the user, destroyed
/// when the device is removed) and the same storage owner.
class SelectionEntry {
  final DeviceRef device;

  /// User-chosen display name, if set. `null` means "fall back to
  /// [DeviceRef.displayName]" (advertised name → raw id).
  final String? customName;

  const SelectionEntry({required this.device, this.customName});

  /// Name to render in the UI: custom name if set, else
  /// `device.displayName`. Trimmed so a custom name of `"  "` doesn't
  /// turn the row into whitespace — the setter rejects whitespace-only
  /// names too, but the getter is the centralized fallback.
  String get displayName {
    final c = customName?.trim();
    if (c == null || c.isEmpty) return device.displayName;
    return c;
  }

  SelectionEntry copyWith({Object? customName = _sentinel}) {
    return SelectionEntry(
      device: device,
      customName: identical(customName, _sentinel)
          ? this.customName
          : customName as String?,
    );
  }

  static const _sentinel = Object();
}

/// User-intent state space (ADR-001 §4): the ordered list of dumbbells
/// the user has selected, plus per-device metadata they own (today: the
/// custom name from §2e; planned: per-device weight override from §2f).
///
/// Lives outside `HomeScreen` so the screen stays a junction box rather
/// than a state container — promote-on-tap, ×-remove, and rename all
/// flow through the model. The model:
///
/// - Hydrates from [Preferences] on construction (the remembered device
///   ids in tap order, plus the customDeviceNames map keyed by id).
/// - Notifies listeners via [ChangeNotifier] on every mutation. The
///   screen rebuilds in reaction; the snapshot stream from `WeightGroup`
///   still drives connection-derived UI.
/// - Persists *verified* state to [Preferences]: rememberedDeviceIds is
///   only written after [markVerified] flips true (HomeScreen calls it
///   on the first ready snapshot), so a Connect attempt that never
///   reaches `isReady` on any device can't poison the warm-start anchor.
///   Custom names persist every change — they're user-typed metadata
///   that doesn't depend on a successful connect.
class SelectionModel extends ChangeNotifier {
  final Preferences _preferences;

  /// In-memory ordered selection. Mutated through [add], [remove], and
  /// the rename path; never via direct list manipulation.
  final List<SelectionEntry> _entries = [];

  /// Flips true the first time [markVerified] is called for the lifetime
  /// of this model — i.e. once at least one selected device has reached
  /// `isReady`. Until then, [_persistRemembered] is a no-op so a Connect
  /// that never resolves doesn't anchor the next cold start to a known-
  /// bad set.
  bool _verified = false;

  SelectionModel({required Preferences preferences})
      : _preferences = preferences {
    _hydrate();
  }

  /// Ordered selected-device entries, in tap order. Returned as an
  /// unmodifiable view so callers can't mutate the backing list and
  /// bypass [notifyListeners].
  List<SelectionEntry> get entries => List.unmodifiable(_entries);

  /// Convenience accessor for callers that only care about the
  /// [DeviceRef] list (e.g. `WeightGroup.add` plumbing).
  List<DeviceRef> get devices => [for (final e in _entries) e.device];

  /// O(N) lookup; N is tiny (a user has 2-4 dumbbells).
  SelectionEntry? entryFor(DeviceRef device) {
    for (final e in _entries) {
      if (e.device == device) return e;
    }
    return null;
  }

  /// Just the user-set custom name for [device], or `null` if the user
  /// hasn't renamed it (or has cleared the rename). Distinct from
  /// [displayNameFor], which always returns a non-null user-facing
  /// string by falling back to the advertised name / id.
  ///
  /// Used by the §2h status-pill toast on the cards: the toast only
  /// includes "(name)" when the user has explicitly named the
  /// dumbbell, never the advertised name (which is duplicated info
  /// next to the device id).
  ///
  /// Consults the in-selection entry first; for a device NOT in the
  /// selection (e.g. it appears only in the bottom scan list), falls
  /// back to [Preferences.customDeviceNames] so a previously-renamed
  /// dumbbell that's been removed still reports the user's name.
  String? customNameFor(DeviceRef device) {
    final entry = entryFor(device);
    final raw = entry?.customName ?? _preferences.customDeviceNames[device.id];
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  /// Display name for a device — custom if the user has renamed it,
  /// else the device's advertised name / id.
  ///
  /// For devices currently in the selection, returns
  /// [SelectionEntry.displayName]. For devices NOT in the selection,
  /// still consults [Preferences.customDeviceNames] so a previously-
  /// renamed dumbbell shows the user's name even when un-selected
  /// (e.g. it appears in the bottom scan list after the user removed
  /// it from the top region, or hasn't promoted it yet on a fresh
  /// launch). Falls back to the device's `displayName` (advertised
  /// name or raw id) as a last resort.
  String displayNameFor(DeviceRef device) {
    final entry = entryFor(device);
    if (entry != null) return entry.displayName;
    final custom = _preferences.customDeviceNames[device.id]?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    return device.displayName;
  }

  /// True iff the model contains an entry for [device].
  bool contains(DeviceRef device) => entryFor(device) != null;

  /// Append [device] to the selection. No-op if the device is already
  /// present. Preserves any custom name carried in from a prior
  /// session — re-promoting a previously-renamed dumbbell keeps the
  /// user's name.
  void add(DeviceRef device) {
    if (contains(device)) return;
    // Look up a custom name from the hydrated map — a device that's
    // in customDeviceNames but not in rememberedDeviceIds is a device
    // the user renamed, then removed, then is now re-promoting. Their
    // earlier rename should still apply.
    final customName = _preferences.customDeviceNames[device.id];
    _entries.add(SelectionEntry(device: device, customName: customName));
    _persistRemembered();
    notifyListeners();
  }

  /// Drop [device] from the selection. The device's custom name in
  /// [Preferences.customDeviceNames] is preserved — re-promoting later
  /// restores it. No-op if the device isn't present.
  void remove(DeviceRef device) {
    final i = _entries.indexWhere((e) => e.device == device);
    if (i < 0) return;
    _entries.removeAt(i);
    _persistRemembered();
    notifyListeners();
  }

  /// Set or clear the user-chosen display name for [device]. Pass a
  /// non-empty string to set; pass `null` (or a trimmed-empty string)
  /// to clear and fall back to the advertised name. No-op if the
  /// device isn't in the selection.
  ///
  /// Persists every change to [Preferences.customDeviceNames] — unlike
  /// the remembered-ids list, custom names are user-typed metadata
  /// that doesn't depend on a successful connect.
  void rename(DeviceRef device, String? name) {
    final i = _entries.indexWhere((e) => e.device == device);
    if (i < 0) return;
    final trimmed = name?.trim();
    final normalized = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final existing = _entries[i];
    if (existing.customName == normalized) return;
    _entries[i] = existing.copyWith(customName: normalized);
    _persistCustomNames();
    notifyListeners();
  }

  /// Mark the current selection as verified — at least one member has
  /// reached `isReady`. Until this is called, [add] / [remove] do not
  /// update [Preferences.rememberedDeviceIds] (the anchor for warm
  /// starts). HomeScreen calls this on the first ready snapshot.
  /// Idempotent.
  void markVerified() {
    if (_verified) return;
    _verified = true;
    _persistRemembered();
  }

  void _hydrate() {
    final remembered = _preferences.rememberedDeviceIds;
    final customNames = _preferences.customDeviceNames;
    for (final id in remembered) {
      _entries.add(SelectionEntry(
        device: DeviceRef(id: id),
        customName: customNames[id],
      ));
    }
  }

  void _persistRemembered() {
    if (!_verified) return;
    // Fire-and-forget — the caller doesn't need to wait, and
    // SharedPreferences writes are single-process / serialized
    // internally. A failure here is a logged debugPrint at worst; we
    // don't block the UI on a write to a small JSON file.
    unawaited(_preferences
        .setRememberedDeviceIds([for (final e in _entries) e.device.id]));
  }

  /// **Invariant** (enforced by [_hydrate] and [add]): every
  /// [SelectionEntry] in [_entries] carries the [Preferences.customDeviceNames]
  /// value for its `device.id` at the time the entry was created. Both
  /// constructors of an entry seed [SelectionEntry.customName] from the
  /// current prefs map, and [rename] is the only path that can change
  /// it — and it always writes a fresh, intentional value.
  ///
  /// That invariant is what lets this method safely *exclude* selected
  /// ids from the "preserved names for non-selected devices" merge
  /// below: a selected device's entry IS the authoritative current
  /// value, so the on-disk entry for the same id would be stale at
  /// best (and equal at worst). Without the invariant, this filter
  /// could drop a previously-named selected device's rename.
  void _persistCustomNames() {
    final out = <String, String>{};
    for (final e in _entries) {
      final c = e.customName;
      if (c != null && c.isNotEmpty) out[e.device.id] = c;
    }
    // Merge with any preserved names for devices NOT currently in the
    // selection (the user removed them but their rename is still on
    // disk). Without this, removing a renamed dumbbell from the
    // selection would wipe the rename — surprising next-time-promote-
    // on-tap behavior.
    final existing = _preferences.customDeviceNames;
    final currentIds = {for (final e in _entries) e.device.id};
    for (final entry in existing.entries) {
      if (!currentIds.contains(entry.key)) out[entry.key] = entry.value;
    }
    unawaited(_preferences.setCustomDeviceNames(out));
  }
}
