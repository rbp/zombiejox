import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/ble/ble_connection_state.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/devices/dumbbell.dart';
import 'package:zombiejox/protocol/dumbbell_state.dart';
import 'package:zombiejox/state/weights.dart';
import 'package:zombiejox/widgets/dumbbell_card.dart';

/// Test double for [Dumbbell] that exposes test-controllable state and
/// connection streams. The base class's BLE plumbing is bypassed via getter
/// overrides; [connect]/[setWeightIndex]/[disconnect] are not used by
/// [DumbbellCard] so they're left alone (will throw if called).
class _FakeDumbbell extends Dumbbell {
  _FakeDumbbell(super.device);

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  final StreamController<BleConnectionState> _conn =
      StreamController<BleConnectionState>.broadcast();
  DumbbellState? _last;

  @override
  Stream<DumbbellState> get states => _states.stream;

  @override
  Stream<BleConnectionState> get connectionState => _conn.stream;

  @override
  DumbbellState? get lastState => _last;

  void emitConnected() => _conn.add(BleConnectionState.connected);
  void emitState(DumbbellState s) {
    _last = s;
    _states.add(s);
  }

  Future<void> dispose() async {
    await _states.close();
    await _conn.close();
  }
}

DeviceRef _device(String id, {String name = ''}) =>
    DeviceRef(id: id, name: name);

Future<void> _pump(WidgetTester tester, Widget w) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
}

void main() {
  testWidgets('shows "Connecting…" when no connection event yet',
      (tester) async {
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester, DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs));
    await tester.pump();

    // Body line spells the state out with an ellipsis; the status chip
    // shows the bare word. `find.text` is exact-match so this only
    // matches the body line, not the chip.
    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('renders weight in lbs once connected and state arrives',
      (tester) async {
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester, DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs));
    fake.emitConnected();
    fake.emitState(
      const DumbbellState(weightIndex: 2, motorActive: false, batteryPct: 88),
    );
    await tester.pump();

    expect(find.text('20 lbs'), findsOneWidget);
    expect(find.text('88%'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);
  });

  testWidgets('renders weight in kg when WeightUnit.kg', (tester) async {
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester, DumbbellCard(dumbbell: fake, unit: WeightUnit.kg));
    fake.emitConnected();
    fake.emitState(
      const DumbbellState(weightIndex: 4, motorActive: false, batteryPct: 50),
    );
    await tester.pump();

    expect(find.text('14.5 kg'), findsOneWidget);
  });

  testWidgets('shows "Moving…" when motorActive is true', (tester) async {
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester, DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs));
    fake.emitConnected();
    fake.emitState(
      const DumbbellState(weightIndex: 2, motorActive: true, batteryPct: 100),
    );
    await tester.pump();

    // Body line is "Moving…"; chip is "Moving". Exact-match `find.text`
    // on the body keeps the assertion specific.
    expect(find.text('Moving…'), findsOneWidget);
    expect(find.text('Idle'), findsNothing);
  });

  testWidgets('em-dash placeholder when no state yet but connected',
      (tester) async {
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester, DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs));
    fake.emitConnected();
    await tester.pump();

    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('falls back to remoteId when advName is empty', (tester) async {
    // DeviceRef with empty name falls back to the id.
    final fake = _FakeDumbbell(_device('AA:BB:CC'));
    addTearDown(fake.dispose);

    await _pump(tester, DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs));
    await tester.pump();

    expect(find.text('AA:BB:CC'), findsOneWidget);
  });
}
