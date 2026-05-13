import 'dart:async';

import 'preferences.dart';
import 'weights.dart';

/// Outcomes [UnitAutoMatcher] fires on its `onOutcome` callback.
enum AutoMatchOutcome {
  /// The connected dumbbells agreed on a unit and the app's display unit
  /// was just nudged to match. `result.unit` carries the value. The UI
  /// surfaces a "Unit set to X to match your dumbbells" SnackBar.
  matched,

  /// Connected dumbbells reported different units. The app's display
  /// unit was left alone; the UI surfaces a "set one in Settings"
  /// SnackBar.
  disagreement,
}

class AutoMatchResult {
  const AutoMatchResult(this.outcome, [this.unit]);
  final AutoMatchOutcome outcome;
  final WeightUnit? unit; // non-null only when outcome == matched
}

/// Snapshot a caller hands to [UnitAutoMatcher.tick]. Decouples the
/// matcher from `WeightGroup` / `Dumbbell` so it's unit-testable as
/// plain Dart, without pumping a widget.
typedef UnitsSnapshot = ({
  /// Distinct known units across all members that have reported one.
  /// The caller is responsible for converting `unitRaw` via
  /// [weightUnitFromRawByte] before passing it in.
  Set<WeightUnit> knownUnits,

  /// How many members have reported a known unit so far. Equal to
  /// `knownUnits.length` when each member reports a distinct value,
  /// larger when some agree.
  int knownUnitCount,

  /// How many members have failed to connect. Failed members are
  /// "accounted for" — they don't contribute a unit but they let the
  /// matcher skip the debounce wait once everything else is in.
  int failedCount,

  /// Total devices the user asked us to connect to.
  int attemptedCount,
});

/// Decides — with no UI dependencies — whether to nudge the app's
/// display unit to match the connected dumbbells'. Lifted out of
/// `HomeScreen` so the state machine is testable as a plain Dart
/// class.
///
/// **Rules:**
/// - If `Preferences.unitExplicitlyChosen` is true → no-op forever.
/// - Otherwise: wait until at least one member reports a known unit.
///   Then if every attempted device is accounted for
///   (`knownUnitCount + failedCount >= attemptedCount`), fire
///   immediately. Else arm a 1.5 s debounce — **once**; subsequent
///   ticks don't reset it, since real dumbbells broadcast `0xD2`
///   ~1 Hz and a resetting timer would never fire on its own.
/// - Outcome fires at most once per matcher instance.
///
/// **Lifecycle:** construct → call [tick] on every relevant event
/// (membership change, per-member state emission, connect failure) →
/// call [dispose] on screen teardown so the timer doesn't outlive the
/// matcher.
class UnitAutoMatcher {
  UnitAutoMatcher({
    required Preferences preferences,
    required void Function(AutoMatchResult) onOutcome,
    Duration debounce = const Duration(milliseconds: 1500),
  })  : _preferences = preferences,
        _onOutcome = onOutcome,
        _debounce = debounce;

  final Preferences _preferences;
  final void Function(AutoMatchResult) _onOutcome;
  final Duration _debounce;

  Timer? _timer;
  bool _decided = false;
  UnitsSnapshot? _last;

  /// Re-evaluate against the current snapshot. Cheap and idempotent —
  /// safe to call from membership changes, every per-member state
  /// emission, and failure handlers.
  void tick(UnitsSnapshot snapshot) {
    if (_decided) return;
    if (_preferences.unitExplicitlyChosen) {
      _decided = true;
      return;
    }
    _last = snapshot;
    if (snapshot.knownUnitCount == 0) return;

    final allAccountedFor = snapshot.knownUnitCount + snapshot.failedCount >=
        snapshot.attemptedCount;
    if (allAccountedFor) {
      _timer?.cancel();
      // Don't await — fire-and-forget. Any prefs-write failure inside
      // _fire is swallowed there.
      _fire();
      return;
    }
    // First arming only — subsequent state pushes don't reset the timer.
    if (_timer != null) return;
    _timer = Timer(_debounce, _fire);
  }

  Future<void> _fire() async {
    if (_decided) return;
    if (_preferences.unitExplicitlyChosen) {
      _decided = true;
      return;
    }
    final snapshot = _last;
    // Defensive: tick() never arms the timer until knownUnitCount > 0,
    // so this branch shouldn't fire in practice. If it ever does, don't
    // mark decided — leave the door open for a future tick.
    if (snapshot == null || snapshot.knownUnits.isEmpty) return;
    _decided = true;
    try {
      if (snapshot.knownUnits.length == 1) {
        final unit = snapshot.knownUnits.single;
        final changed = await _preferences.setUnitIfNotExplicit(unit);
        if (changed) {
          _onOutcome(AutoMatchResult(AutoMatchOutcome.matched, unit));
        }
      } else {
        _onOutcome(const AutoMatchResult(AutoMatchOutcome.disagreement));
      }
    } catch (_) {
      // A SharedPreferences write failure shouldn't tear down the
      // screen. Decision is already marked fired — we won't retry.
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
