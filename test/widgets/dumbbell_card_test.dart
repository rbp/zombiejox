import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/ble/ble_connection_state.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/devices/dumbbell.dart';
import 'package:zombiejox/devices/weight_group.dart'
    show RetryPhase, RetryState;
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
  void emitDisconnected() => _conn.add(BleConnectionState.disconnected);
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

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
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

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
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

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.kg, onRemove: () {}));
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

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
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

  testWidgets(
      'BLE-connected but no state frame yet → activity glyph (not the '
      'old "—" weight placeholder)', (tester) async {
    // §2b: the right-hand cluster shows a static
    // `Icons.bluetooth_searching` glyph during Connecting /
    // Reconnecting instead of the bare em-dash — communicates "BLE
    // activity here" through context.
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
    fake.emitConnected();
    await tester.pump();

    expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget,
        reason: 'connecting + no state ⇒ activity glyph slot');
    expect(find.text('—'), findsNothing,
        reason: 'em-dash replaced by the activity glyph');
  });

  testWidgets(
      'BLE-connected but no state frame yet → body "Connecting…" '
      '(not "Idle") — a half-responsive device with no `0xD1` reply '
      'must not look ready', (tester) async {
    // Regression for the on-device case where a depleted-battery dock
    // briefly wakes its radio (BLE link succeeds) but the firmware
    // never replies to `queryStatus`. Before the fix, the card showed
    // "Idle" with a "—" weight — misleadingly close to a working state.
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
    fake.emitConnected();
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget,
        reason: 'state == null ⇒ honestly show Connecting…');
    expect(find.text('Connecting'), findsOneWidget,
        reason: 'and the status chip');
    expect(find.text('Idle'), findsNothing,
        reason: 'must NOT claim Idle while no state frame has arrived');
  });

  testWidgets('falls back to remoteId when advName is empty', (tester) async {
    // DeviceRef with empty name falls back to the id.
    final fake = _FakeDumbbell(_device('AA:BB:CC'));
    addTearDown(fake.dispose);

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
    await tester.pump();

    expect(find.text('AA:BB:CC'), findsOneWidget);
  });

  testWidgets('onRemove → × icon renders and tap fires the callback',
      (tester) async {
    var removes = 0;
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(
      tester,
      DumbbellCard(
        dumbbell: fake,
        unit: WeightUnit.lbs,
        onRemove: () => removes++,
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(removes, 1);
  });

  testWidgets(
      'initial "disconnected" event before connect resolves → still '
      'reads as "Connecting…", NOT the error-coloured "Disconnected" '
      '(regression — Copilot review on PR #22)', (tester) async {
    // BluetoothDevice.connectionState emits an initial `disconnected`
    // value at subscription time. Without the `state != null` gate,
    // newly-added cards would flash an error-coloured "Disconnected"
    // for one frame before settling.
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
    fake.emitDisconnected();
    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsNothing,
        reason: 'no state frame yet ⇒ still in initial-connecting phase');
    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets(
      'retryState present → "Reconnecting…" chip + body (preempts the '
      'plain "Disconnected" fallback)', (tester) async {
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(
      tester,
      DumbbellCard(
        dumbbell: fake,
        unit: WeightUnit.lbs,
        onRemove: () {},
        retryState: const RetryState(phase: RetryPhase.waiting, attempt: 1),
      ),
    );
    fake.emitConnected();
    fake.emitState(
      const DumbbellState(weightIndex: 2, motorActive: false, batteryPct: 88),
    );
    await tester.pump();
    // Now simulate a drop.
    fake.emitDisconnected();
    await tester.pumpAndSettle();

    expect(find.text('Reconnecting…'), findsOneWidget,
        reason: 'retryState ⇒ Reconnecting body line');
    // Status chip says "Reconnecting" (no ellipsis).
    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.text('Disconnected'), findsNothing,
        reason: 'retryState preempts the bare "Disconnected" fallback');
  });

  testWidgets(
      'defensive "Disconnected" fallback keeps the last known weight '
      'visible — does NOT swap it for the activity glyph (Copilot '
      'review on PR #25)', (tester) async {
    // When connState=disconnected AND state != null (a drop after the
    // device was once ready, with no retryState because the supervisor
    // didn't run for this case), the right-hand cluster should keep
    // showing the known weight, not the bluetooth_searching glyph.
    // Activity glyph only when we don't know the weight (state==null).
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
    fake.emitConnected();
    fake.emitState(
      const DumbbellState(weightIndex: 2, motorActive: false, batteryPct: 88),
    );
    await tester.pump();
    expect(find.text('20 lbs'), findsOneWidget);

    // Drop without retry supervisor — the defensive fallback path.
    fake.emitDisconnected();
    await tester.pumpAndSettle();

    expect(find.text('20 lbs'), findsOneWidget,
        reason: 'known weight must still show in disconnected fallback');
    expect(find.byIcon(Icons.bluetooth_searching), findsNothing,
        reason: 'activity glyph only when state==null');
  });

  testWidgets(
      'connection drop after a successful connect → "Disconnected" '
      'chip + body line (not the muted "Connecting…" fallback)',
      (tester) async {
    final fake = _FakeDumbbell(_device('AA:01'));
    addTearDown(fake.dispose);

    await _pump(tester,
        DumbbellCard(dumbbell: fake, unit: WeightUnit.lbs, onRemove: () {}));
    fake.emitConnected();
    fake.emitState(
      const DumbbellState(weightIndex: 2, motorActive: false, batteryPct: 88),
    );
    await tester.pump();
    expect(find.text('Idle'), findsOneWidget);

    // Mid-session drop: BleConnection emits `disconnected`. Pump
    // twice — the broadcast stream delivers asynchronously on a
    // microtask, then the StreamBuilder schedules a rebuild for the
    // next frame.
    fake.emitDisconnected();
    await tester.pumpAndSettle();

    // Body line spells "Disconnected"; the status chip mirrors it.
    expect(find.text('Disconnected'), findsWidgets,
        reason: 'must NOT fall back to the "Connecting…" wording');
    expect(find.text('Idle'), findsNothing);
    expect(find.text('Connecting…'), findsNothing);
  });
}
