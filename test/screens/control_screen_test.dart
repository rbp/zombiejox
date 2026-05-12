import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/ble/ble_connection_state.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/devices/dumbbell.dart';
import 'package:zombiejox/devices/weight_group.dart';
import 'package:zombiejox/protocol/dumbbell_state.dart';
import 'package:zombiejox/screens/control_screen.dart';
import 'package:zombiejox/state/preferences.dart';
import 'package:zombiejox/state/weights.dart';
import 'package:zombiejox/widgets/failed_device_card.dart';

/// Connects-instantly fake; lets the test push state values for assertions.
class _FakeDumbbell extends Dumbbell {
  _FakeDumbbell(super.device);

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  final StreamController<BleConnectionState> _conn =
      StreamController<BleConnectionState>.broadcast();
  DumbbellState? _last;
  final List<int> setWeightCalls = [];
  bool failSetWeight = false;
  bool failConnect = false;

  @override
  Stream<DumbbellState> get states => _states.stream;

  @override
  Stream<BleConnectionState> get connectionState => _conn.stream;

  @override
  DumbbellState? get lastState => _last;

  @override
  Future<void> connect() async {
    if (failConnect) {
      throw StateError('fake connect failure');
    }
    _conn.add(BleConnectionState.connected);
  }

  @override
  Future<void> setWeightIndex(int index) async {
    setWeightCalls.add(index);
    if (failSetWeight) {
      throw StateError('fake set-weight failure');
    }
    _last = DumbbellState(
      weightIndex: index,
      motorActive: false,
      batteryPct: _last?.batteryPct,
    );
    _states.add(_last!);
  }

  @override
  Future<void> disconnect() async {
    await _states.close();
    await _conn.close();
  }

  void emitState(DumbbellState s) {
    _last = s;
    _states.add(s);
  }
}

DeviceRef _device(String id) => DeviceRef(id: id);

Future<Preferences> _freshPrefs() async {
  SharedPreferences.setMockInitialValues({'units': 'lbs'});
  return Preferences.load();
}

void main() {
  testWidgets('empty devices list → "No dumbbells connected"', (tester) async {
    final prefs = await _freshPrefs();
    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(devices: const [], preferences: prefs),
    ));
    await tester.pump();
    expect(find.text('No dumbbells connected.'), findsOneWidget);
  });

  testWidgets('renders one DumbbellCard per connected device', (tester) async {
    final prefs = await _freshPrefs();
    final group = WeightGroup(newDumbbell: (d) => _FakeDumbbell(d));

    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01'), _device('AA:02')],
        preferences: prefs,
        createWeightGroup: () => group,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsNWidgets(2));
  });

  testWidgets('weight button tap fans out to every dumbbell', (tester) async {
    final prefs = await _freshPrefs();
    final fakes = <_FakeDumbbell>[];
    final group = WeightGroup(newDumbbell: (d) {
      final f = _FakeDumbbell(d);
      fakes.add(f);
      return f;
    });

    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01'), _device('AA:02')],
        preferences: prefs,
        createWeightGroup: () => group,
      ),
    ));
    await tester.pumpAndSettle();

    // Push an idle state on both so the buttons become enabled.
    for (final f in fakes) {
      f.emitState(
        const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
      );
    }
    await tester.pumpAndSettle();

    await tester.tap(find.text('32 lbs'));
    await tester.pumpAndSettle();

    expect(fakes, hasLength(2));
    for (final f in fakes) {
      expect(f.setWeightCalls, [4]); // index 4 = 32 lbs
    }
  });

  testWidgets(
      'weight buttons enable as soon as ANY dumbbell is ready; tap fans out '
      'only to ready members so an offline pair-mate never blocks the rest',
      (tester) async {
    final prefs = await _freshPrefs();
    final fakes = <_FakeDumbbell>[];
    final group = WeightGroup(newDumbbell: (d) {
      final f = _FakeDumbbell(d);
      fakes.add(f);
      return f;
    });

    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01'), _device('AA:02')],
        preferences: prefs,
        createWeightGroup: () => group,
      ),
    ));
    await tester.pumpAndSettle();
    expect(fakes, hasLength(2));

    // No fake has emitted state yet — every weight button is disabled so a
    // fast tap can't hit an uninitialized TX characteristic.
    var allButtons =
        tester.widgetList<FilledButton>(find.byType(FilledButton)).toList();
    expect(allButtons, hasLength(8));
    for (final b in allButtons) {
      expect(b.onPressed, isNull,
          reason: 'no member ready → every button disabled');
    }

    // Tapping while disabled is a guarded no-op.
    await tester.tap(find.text('20 lbs'), warnIfMissed: false);
    await tester.pumpAndSettle();
    for (final f in fakes) {
      expect(f.setWeightCalls, isEmpty);
    }

    // Bring ONE fake ready — leaves the other "stuck connecting" forever
    // (simulating an offline / out-of-range pair-mate).
    fakes[0].emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();

    // Buttons must enable now — we don't want one offline dumbbell to block
    // the user from controlling the one that's actually working.
    allButtons =
        tester.widgetList<FilledButton>(find.byType(FilledButton)).toList();
    final enabledCount = allButtons.where((b) => b.onPressed != null).length;
    expect(enabledCount, 8,
        reason: 'one ready ⇒ buttons enabled; offline mate ignored');

    // Tap → fan-out reaches only the ready fake.
    await tester.tap(find.text('14 lbs'));
    await tester.pumpAndSettle();
    expect(fakes[0].setWeightCalls, [1]);
    expect(fakes[1].setWeightCalls, isEmpty,
        reason: 'WeightGroup must skip the not-ready member');

    // When the offline dumbbell finally comes online, taps fan out to
    // both.
    fakes[1].emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('20 lbs'));
    await tester.pumpAndSettle();
    expect(fakes[0].setWeightCalls, [1, 2]);
    expect(fakes[1].setWeightCalls, [2]);
  });

  testWidgets(
      'a failing setWeightIndex surfaces a SnackBar (not an uncaught error)',
      (tester) async {
    final prefs = await _freshPrefs();
    final fakes = <_FakeDumbbell>[];
    final group = WeightGroup(newDumbbell: (d) {
      final f = _FakeDumbbell(d);
      fakes.add(f);
      return f;
    });

    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01')],
        preferences: prefs,
        createWeightGroup: () => group,
      ),
    ));
    await tester.pumpAndSettle();

    // Make the dumbbell ready, then arm a failure for the next write.
    fakes.single.emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    fakes.single.failSetWeight = true;

    await tester.tap(find.text('20 lbs'));
    await tester.pumpAndSettle();

    // The failure must have been awaited and turned into a SnackBar — not
    // a flutter framework "unhandled error" that crashes the test.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Failed to set weight'), findsOneWidget);
  });

  testWidgets(
      'a connect failure renders a FailedDeviceCard at the bottom of the list',
      (tester) async {
    final prefs = await _freshPrefs();
    final fakes = <_FakeDumbbell>[];
    final group = WeightGroup(newDumbbell: (d) {
      final f = _FakeDumbbell(d)..failConnect = true;
      fakes.add(f);
      return f;
    });

    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01')],
        preferences: prefs,
        createWeightGroup: () => group,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(FailedDeviceCard), findsOneWidget);
    expect(find.text('Failed to connect'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    // The "ghost-card" approach: the device is no longer in the group but
    // the user still sees a visual entry for it.
    expect(group.dumbbells, isEmpty);
  });

  testWidgets(
      'tapping refresh on a failed card retries; on success the failed card '
      'disappears and a connecting/connected card takes its place',
      (tester) async {
    final prefs = await _freshPrefs();
    final fakes = <_FakeDumbbell>[];
    final group = WeightGroup(newDumbbell: (d) {
      // First attempt fails; subsequent attempts (a fresh fake per call)
      // succeed.
      final attemptCount = fakes.length + 1;
      final f = _FakeDumbbell(d)..failConnect = (attemptCount == 1);
      fakes.add(f);
      return f;
    });

    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01')],
        preferences: prefs,
        createWeightGroup: () => group,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(FailedDeviceCard), findsOneWidget);

    // Tap refresh.
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    // The failed card is gone; the device is back in the group.
    expect(find.byType(FailedDeviceCard), findsNothing);
    expect(group.dumbbells, hasLength(1));
    expect(fakes, hasLength(2)); // first attempt failed; second succeeded
  });

  testWidgets(
      'cards keep their original selection-order slots: retrying a failed '
      'device does not visually move it past its neighbours', (tester) async {
    final prefs = await _freshPrefs();
    final fakes = <_FakeDumbbell>[];
    final group = WeightGroup(newDumbbell: (d) {
      // First attempt for AA:01 succeeds; first attempt for AA:02 fails,
      // second attempt for AA:02 succeeds. The retry test is about whether
      // AA:02 moves above AA:01 when it transitions failed → connected.
      final isAa01 = d.id == 'AA:01';
      final attemptsForThisDevice =
          fakes.where((f) => f.device.id == d.id).length;
      final f = _FakeDumbbell(d)
        ..failConnect = !isAa01 && attemptsForThisDevice == 0;
      fakes.add(f);
      return f;
    });

    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01'), _device('AA:02')],
        preferences: prefs,
        createWeightGroup: () => group,
      ),
    ));
    await tester.pumpAndSettle();

    // Initial state: AA:01 connected on top, AA:02 failed below it.
    expect(find.byType(FailedDeviceCard), findsOneWidget);
    expect(tester.getTopLeft(find.text('AA:01')).dy,
        lessThan(tester.getTopLeft(find.text('AA:02')).dy),
        reason: 'AA:01 was selected first, must render above AA:02');

    // Retry AA:02 → succeeds. The pre-fix bug: AA:02 would jump to slot 1
    // because connected cards were rendered before failed ones. With the
    // fix, the order follows widget.devices, so AA:01 must still be above.
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(find.byType(FailedDeviceCard), findsNothing);

    expect(tester.getTopLeft(find.text('AA:01')).dy,
        lessThan(tester.getTopLeft(find.text('AA:02')).dy),
        reason: 'after retry, AA:01 must still render above AA:02 — '
            'the retried card must not jump to the top');
  });

  testWidgets(
      'onAnyConnected fires exactly once when the first member becomes ready '
      '— and not on subsequent state emissions or members becoming ready',
      (tester) async {
    final prefs = await _freshPrefs();
    final fakes = <_FakeDumbbell>[];
    final group = WeightGroup(newDumbbell: (d) {
      final f = _FakeDumbbell(d);
      fakes.add(f);
      return f;
    });

    var fired = 0;
    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01'), _device('AA:02')],
        preferences: prefs,
        createWeightGroup: () => group,
        onAnyConnected: () => fired++,
      ),
    ));
    await tester.pumpAndSettle();

    expect(fired, 0,
        reason: 'no state has been emitted yet → no member is ready');

    // First state on the first fake → fires once.
    fakes[0].emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    expect(fired, 1);

    // Subsequent state emissions on the same fake → no re-fire.
    fakes[0].emitState(
      const DumbbellState(weightIndex: 1, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    expect(fired, 1);

    // The second fake becoming ready also doesn't re-fire — it's
    // once-per-screen, not once-per-member. ScanScreen wants the device
    // set committed to remembered-storage exactly once, on the first
    // verified successful connect of *any* member.
    fakes[1].emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    expect(fired, 1);
  });

  testWidgets(
      'onAnyConnected never fires when every member fails to connect '
      '— so a failed Connect-tap does not poison the remembered set',
      (tester) async {
    final prefs = await _freshPrefs();
    final group = WeightGroup(newDumbbell: (d) {
      final f = _FakeDumbbell(d)..failConnect = true;
      return f;
    });

    var fired = 0;
    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01'), _device('AA:02')],
        preferences: prefs,
        createWeightGroup: () => group,
        onAnyConnected: () => fired++,
      ),
    ));
    await tester.pumpAndSettle();

    expect(fired, 0,
        reason: 'all members failed to connect → no member ever ready');
  });

  testWidgets('shows kg labels when preference is kg', (tester) async {
    SharedPreferences.setMockInitialValues({'units': 'kg'});
    final prefs = await Preferences.load();
    final group = WeightGroup(newDumbbell: (d) => _FakeDumbbell(d));

    await tester.pumpWidget(MaterialApp(
      home: ControlScreen(
        devices: [_device('AA:01')],
        preferences: prefs,
        createWeightGroup: () => group,
      ),
    ));
    await tester.pumpAndSettle();

    // First and last weight buttons in kg (3.6 / 22.7).
    expect(find.text('3.6 kg'), findsOneWidget);
    expect(find.text('22.7 kg'), findsOneWidget);
    expect(find.text('8 lbs'), findsNothing);
  });

  // Auto-match-from-dock: when all connected dumbbells agree on a unit
  // and the user hasn't picked one yet, ControlScreen nudges the app's
  // display unit to match (with a SnackBar). Debounces 1.5s after the
  // first ready to give slow-to-connect mates a chance to vote.

  group('auto-match dock unit', () {
    Future<Preferences> prefs(
        {String unit = 'lbs', bool explicit = false}) async {
      SharedPreferences.setMockInitialValues({
        'units': unit,
        'unit_explicitly_chosen': explicit,
      });
      return Preferences.load();
    }

    DumbbellState stateWithUnit({required int unitRaw, int weightIndex = 0}) =>
        DumbbellState(
          weightIndex: weightIndex,
          motorActive: false,
          batteryPct: 80,
          unitRaw: unitRaw,
        );

    testWidgets(
        'all members agree on kg + user has not chosen → app set to kg, '
        'SnackBar shown', (tester) async {
      final p = await prefs(unit: 'lbs');
      final fakes = <_FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01'), _device('AA:02')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();

      for (final f in fakes) {
        f.emitState(stateWithUnit(unitRaw: 0x01));
      }
      // Both ready ⇒ "all accounted for" fires the decision immediately,
      // no debounce wait needed.
      await tester.pumpAndSettle();

      expect(p.unit.value, WeightUnit.kg);
      expect(p.unitExplicitlyChosen, isFalse,
          reason: 'auto-match must not flip the explicit-choice flag');
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Unit set to kg'), findsOneWidget);
    });

    testWidgets('app already at the auto-matched unit → no SnackBar',
        (tester) async {
      final p = await prefs(unit: 'kg');
      final fakes = <_FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();
      fakes.single.emitState(stateWithUnit(unitRaw: 0x01));
      await tester.pumpAndSettle();

      expect(p.unit.value, WeightUnit.kg);
      expect(find.byType(SnackBar), findsNothing,
          reason: 'value already matched ⇒ nothing to announce');
    });

    testWidgets(
        'members disagree → no preference change, "different units" SnackBar',
        (tester) async {
      final p = await prefs(unit: 'lbs');
      final fakes = <_FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01'), _device('AA:02')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();

      fakes[0].emitState(stateWithUnit(unitRaw: 0x00)); // lbs
      fakes[1].emitState(stateWithUnit(unitRaw: 0x01)); // kg
      await tester.pumpAndSettle();

      expect(p.unit.value, WeightUnit.lbs,
          reason: 'disagreement must not change the unit');
      expect(find.textContaining('different units'), findsOneWidget);
    });

    testWidgets(
        'user has explicitly chosen → auto-match is a no-op (no SnackBar, '
        'no preference change)', (tester) async {
      final p = await prefs(unit: 'lbs', explicit: true);
      final fakes = <_FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();
      fakes.single.emitState(stateWithUnit(unitRaw: 0x01));
      await tester.pumpAndSettle();

      expect(p.unit.value, WeightUnit.lbs);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
        'debounce: a slow second member that disagrees still wins — '
        'the first ready does not get to decide alone within 1.5s',
        (tester) async {
      final p = await prefs(unit: 'lbs');
      final fakes = <_FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01'), _device('AA:02')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();

      // Only the first fake is ready so far. Pump just under the
      // debounce window so the timer hasn't fired yet.
      fakes[0].emitState(stateWithUnit(unitRaw: 0x01));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(p.unit.value, WeightUnit.lbs,
          reason: 'still within debounce, no decision yet');

      // The second member finally arrives with a disagreeing value.
      // "All accounted for" fires the decision immediately.
      fakes[1].emitState(stateWithUnit(unitRaw: 0x00));
      await tester.pumpAndSettle();

      expect(p.unit.value, WeightUnit.lbs, reason: 'disagreement ⇒ no change');
      expect(find.textContaining('different units'), findsOneWidget);
    });

    testWidgets(
        'one member ready + one member failed = "accounted for" → '
        'decide on the lone vote without waiting the full debounce',
        (tester) async {
      final p = await prefs(unit: 'lbs');
      final fakes = <_FakeDumbbell>[];
      // First device succeeds; second fails to connect.
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        if (fakes.isNotEmpty) f.failConnect = true;
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01'), _device('AA:02')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();
      // Only the first one becomes ready.
      fakes[0].emitState(stateWithUnit(unitRaw: 0x01));
      await tester.pumpAndSettle();

      // 1 ready + 1 failed = 2 attempted: "all accounted for". Decision
      // fires immediately without consuming the full 1.5s debounce.
      expect(p.unit.value, WeightUnit.kg);
      expect(find.textContaining('Unit set to kg'), findsOneWidget);
    });

    testWidgets('unknown unit byte → no decision (do not guess at the mapping)',
        (tester) async {
      final p = await prefs(unit: 'lbs');
      final fakes = <_FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();
      // 0x42 isn't a known unit byte — silently leave the app unit alone.
      fakes.single.emitState(stateWithUnit(unitRaw: 0x42));
      await tester.pumpAndSettle();

      expect(p.unit.value, WeightUnit.lbs);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
        'isReady without a known unit byte (post-connect battery read window) '
        'must not lock the decision — the eventual 0xD1 reply still gets to '
        'auto-match', (tester) async {
      // Regression: previously, _autoMatchDecided was set the moment "all
      // accounted for" hit. Dumbbell.isReady becomes true on the
      // post-connect battery read — BEFORE the 0xD1 reply with the unit
      // byte arrives — so the old code would decide with an empty units
      // snapshot and permanently disable auto-match for the screen.
      final p = await prefs(unit: 'lbs');
      final fakes = <_FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();

      // Simulate the post-connect battery read: isReady becomes true,
      // unitRaw is still null.
      fakes.single.emitState(const DumbbellState(
        weightIndex: 0,
        motorActive: false,
        batteryPct: 80,
      ));
      await tester.pumpAndSettle();
      expect(p.unit.value, WeightUnit.lbs,
          reason: 'no known unit yet — must not decide');
      expect(find.byType(SnackBar), findsNothing);

      // 0xD1 reply finally arrives with a unit byte.
      fakes.single.emitState(stateWithUnit(unitRaw: 0x01));
      await tester.pumpAndSettle();

      expect(p.unit.value, WeightUnit.kg,
          reason: 'auto-match must still fire once the unit byte arrives');
      expect(find.textContaining('Unit set to kg'), findsOneWidget);
    });

    testWidgets(
        '1 Hz 0xD2 broadcasts during the debounce window do NOT reset the '
        'timer — it fires 1.5s after the first qualifying event regardless '
        'of subsequent state pushes', (tester) async {
      // Regression: real dumbbells emit 0xD2 broadcasts ~1 Hz. Previously
      // _maybeArmAutoMatch cancelled + restarted the timer on every
      // emission, so on a partly-online group the debounce never fired
      // and auto-match was perma-stuck.
      final p = await prefs(unit: 'lbs');
      final fakes = <_FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await tester.pumpWidget(MaterialApp(
        home: ControlScreen(
          devices: [_device('AA:01'), _device('AA:02')],
          preferences: p,
          createWeightGroup: () => group,
        ),
      ));
      await tester.pumpAndSettle();

      // First member ready with kg; second is offline. Not "all
      // accounted for", so the 1.5s debounce arms.
      fakes[0].emitState(stateWithUnit(unitRaw: 0x01));
      await tester.pump(const Duration(milliseconds: 500));
      expect(p.unit.value, WeightUnit.lbs,
          reason: 'still within debounce — no decision yet');

      // Three more state pushes from the now-ready dumbbell at ~1 Hz —
      // mirroring the 0xD2 broadcast cadence on a real device. Pre-fix,
      // each one cancelled + restarted the timer, pushing the decision
      // out indefinitely.
      fakes[0].emitState(stateWithUnit(unitRaw: 0x01, weightIndex: 1));
      await tester.pump(const Duration(milliseconds: 400));
      fakes[0].emitState(stateWithUnit(unitRaw: 0x01, weightIndex: 2));
      await tester.pump(const Duration(milliseconds: 400));
      fakes[0].emitState(stateWithUnit(unitRaw: 0x01, weightIndex: 1));
      // Total elapsed ≈ 1300 ms — push a bit past the 1500 ms threshold
      // measured from the *first* qualifying event.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(p.unit.value, WeightUnit.kg,
          reason: 'the timer was armed at the first qualifying event; later '
              'state pushes must not reset it');
      expect(find.textContaining('Unit set to kg'), findsOneWidget);
    });
  });
}
