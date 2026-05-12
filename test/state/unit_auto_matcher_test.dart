import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/state/preferences.dart';
import 'package:zombiejox/state/unit_auto_matcher.dart';
import 'package:zombiejox/state/weights.dart';

UnitsSnapshot _snap({
  Set<WeightUnit>? knownUnits,
  int? knownUnitCount,
  int failedCount = 0,
  required int attemptedCount,
}) {
  final units = knownUnits ?? const <WeightUnit>{};
  return (
    knownUnits: units,
    knownUnitCount: knownUnitCount ?? units.length,
    failedCount: failedCount,
    attemptedCount: attemptedCount,
  );
}

Future<Preferences> _prefs({String unit = 'lbs', bool explicit = false}) async {
  SharedPreferences.setMockInitialValues({
    'units': unit,
    'unit_explicitly_chosen': explicit,
  });
  return Preferences.load();
}

// Short debounce so debounce-related tests don't slow the suite.
const _testDebounce = Duration(milliseconds: 40);

void main() {
  group('UnitAutoMatcher', () {
    test(
        'agreement + every attempted device accounted-for → '
        'fires matched immediately', () async {
      final prefs = await _prefs(unit: 'lbs');
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 1));
      // _fire schedules a microtask via the async setUnit. Yield once.
      await Future<void>.delayed(Duration.zero);

      expect(outcomes, hasLength(1));
      expect(outcomes.single.outcome, AutoMatchOutcome.matched);
      expect(outcomes.single.unit, WeightUnit.kg);
      expect(prefs.unit.value, WeightUnit.kg);
    });

    test('agreement but value already matches → no outcome', () async {
      final prefs = await _prefs(unit: 'kg');
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 1));
      await Future<void>.delayed(Duration.zero);

      expect(outcomes, isEmpty,
          reason: 'setUnitIfNotExplicit returned false ⇒ no SnackBar');
    });

    test('disagreement → fires disagreement, leaves unit alone', () async {
      final prefs = await _prefs(unit: 'lbs');
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      m.tick(_snap(
        knownUnits: {WeightUnit.lbs, WeightUnit.kg},
        knownUnitCount: 2,
        attemptedCount: 2,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(outcomes, hasLength(1));
      expect(outcomes.single.outcome, AutoMatchOutcome.disagreement);
      expect(outcomes.single.unit, isNull);
      expect(prefs.unit.value, WeightUnit.lbs);
    });

    test('user explicitly chose → no outcome, ever', () async {
      final prefs = await _prefs(unit: 'lbs', explicit: true);
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 1));
      await Future<void>.delayed(Duration.zero);
      m.tick(_snap(
        knownUnits: {WeightUnit.lbs, WeightUnit.kg},
        knownUnitCount: 2,
        attemptedCount: 2,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(outcomes, isEmpty);
      expect(prefs.unit.value, WeightUnit.lbs);
    });

    test('zero known units → no decision, no flag latched', () async {
      // Mirrors the post-connect window where a member is "ready" but
      // unitRaw is still null. The matcher must wait, not lock out
      // forever.
      final prefs = await _prefs(unit: 'lbs');
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      m.tick(_snap(attemptedCount: 1));
      m.tick(_snap(attemptedCount: 1));
      await Future<void>.delayed(Duration.zero);
      expect(outcomes, isEmpty);

      // Now a unit arrives — should fire.
      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 1));
      await Future<void>.delayed(Duration.zero);
      expect(outcomes, hasLength(1));
      expect(outcomes.single.outcome, AutoMatchOutcome.matched);
    });

    test(
        'partial accounting → waits the debounce, then fires with what '
        'voted', () async {
      final prefs = await _prefs(unit: 'lbs');
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      // One ready with kg, second still pending.
      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 2));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(outcomes, isEmpty, reason: 'still inside the 40ms debounce');

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(outcomes, hasLength(1));
      expect(outcomes.single.outcome, AutoMatchOutcome.matched);
    });

    test(
        'subsequent ticks within the debounce window do NOT reset the '
        'timer — real devices broadcast ~1 Hz, a resetting timer would '
        'never fire on its own', () async {
      final prefs = await _prefs(unit: 'lbs');
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      // Arm the debounce.
      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 2));
      // Three additional ticks before the 40ms is up — simulating the
      // 0xD2 broadcast cadence on a real device. If they reset the
      // timer, the test will be empty at the assert.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 2));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 2));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 2));
      // Total elapsed so far ≈ 30 ms — push past the 40 ms threshold
      // measured from the first qualifying tick.
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(outcomes, hasLength(1));
      expect(outcomes.single.outcome, AutoMatchOutcome.matched);
    });

    test('outcome fires at most once per matcher', () async {
      final prefs = await _prefs(unit: 'lbs');
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 1));
      await Future<void>.delayed(Duration.zero);
      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 1));
      m.tick(_snap(
        knownUnits: {WeightUnit.lbs, WeightUnit.kg},
        knownUnitCount: 2,
        attemptedCount: 2,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(outcomes, hasLength(1));
    });

    test('dispose cancels the pending debounce — no late outcome', () async {
      final prefs = await _prefs(unit: 'lbs');
      final outcomes = <AutoMatchResult>[];
      final m = UnitAutoMatcher(
        preferences: prefs,
        onOutcome: outcomes.add,
        debounce: _testDebounce,
      );

      m.tick(_snap(knownUnits: {WeightUnit.kg}, attemptedCount: 2));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      m.dispose();
      // Wait well past the debounce — the timer must not fire.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(outcomes, isEmpty);
    });
  });
}
