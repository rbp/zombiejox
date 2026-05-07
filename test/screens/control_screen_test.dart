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

/// Connects-instantly fake; lets the test push state values for assertions.
class _FakeDumbbell extends Dumbbell {
  _FakeDumbbell(super.device);

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  final StreamController<BluetoothConnectionState> _conn =
      StreamController<BluetoothConnectionState>.broadcast();
  DumbbellState? _last;
  final List<int> setWeightCalls = [];

  @override
  Stream<DumbbellState> get states => _states.stream;

  @override
  Stream<BluetoothConnectionState> get connectionState => _conn.stream;

  @override
  DumbbellState? get lastState => _last;

  @override
  Future<void> connect() async {
    _conn.add(BluetoothConnectionState.connected);
  }

  @override
  Future<void> setWeightIndex(int index) async {
    setWeightCalls.add(index);
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

  testWidgets('weight buttons stay disabled until every dumbbell is ready',
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

    // Initially neither fake has emitted state — every weight button must
    // be disabled (its onPressed is null) so a fast tap can't reach the
    // not-yet-connected TX characteristic.
    final allButtons =
        tester.widgetList<FilledButton>(find.byType(FilledButton)).toList();
    expect(allButtons, hasLength(8));
    for (final b in allButtons) {
      expect(b.onPressed, isNull,
          reason: 'every weight button must be disabled before isReady');
    }

    // Tapping a button while disabled is a no-op — verifies the guard.
    await tester.tap(find.text('20 lbs'), warnIfMissed: false);
    await tester.pumpAndSettle();
    for (final f in fakes) {
      expect(f.setWeightCalls, isEmpty);
    }

    // Bring one fake ready; buttons must still be disabled because the
    // *other* one hasn't reported state yet.
    fakes[0].emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    for (final b
        in tester.widgetList<FilledButton>(find.byType(FilledButton))) {
      expect(b.onPressed, isNull,
          reason: 'one ready, one not — buttons must still be disabled');
    }

    // Bring the second one ready; buttons enable.
    fakes[1].emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    final enabledCount = tester
        .widgetList<FilledButton>(find.byType(FilledButton))
        .where((b) => b.onPressed != null)
        .length;
    expect(enabledCount, 8, reason: 'all buttons enabled once both ready');

    // And now the tap reaches both fakes.
    await tester.tap(find.text('14 lbs'));
    await tester.pumpAndSettle();
    for (final f in fakes) {
      expect(f.setWeightCalls, [1]);
    }
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
