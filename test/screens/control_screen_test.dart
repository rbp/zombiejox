import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/devices/dumbbell.dart';
import 'package:zombiejox/devices/weight_group.dart';
import 'package:zombiejox/protocol/dumbbell_state.dart';
import 'package:zombiejox/screens/control_screen.dart';
import 'package:zombiejox/state/preferences.dart';
import 'package:zombiejox/widgets/failed_device_card.dart';

/// Connects-instantly fake; lets the test push state values for assertions.
class _FakeDumbbell extends Dumbbell {
  _FakeDumbbell(super.device);

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  final StreamController<BluetoothConnectionState> _conn =
      StreamController<BluetoothConnectionState>.broadcast();
  DumbbellState? _last;
  final List<int> setWeightCalls = [];
  bool failSetWeight = false;
  bool failConnect = false;

  @override
  Stream<DumbbellState> get states => _states.stream;

  @override
  Stream<BluetoothConnectionState> get connectionState => _conn.stream;

  @override
  DumbbellState? get lastState => _last;

  @override
  Future<void> connect() async {
    if (failConnect) {
      throw StateError('fake connect failure');
    }
    _conn.add(BluetoothConnectionState.connected);
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

BluetoothDevice _device(String id) =>
    BluetoothDevice(remoteId: DeviceIdentifier(id));

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
      final isAa01 = d.remoteId.str == 'AA:01';
      final attemptsForThisDevice =
          fakes.where((f) => f.device.remoteId.str == d.remoteId.str).length;
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
}
