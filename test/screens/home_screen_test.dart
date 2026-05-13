import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/ble/ble_connection_state.dart';
import 'package:zombiejox/ble/ble_scanner.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/devices/dumbbell.dart';
import 'package:zombiejox/devices/weight_group.dart';
import 'package:zombiejox/protocol/dumbbell_state.dart';
import 'package:zombiejox/screens/home_screen.dart';
import 'package:zombiejox/screens/permission_screen.dart';
import 'package:zombiejox/state/preferences.dart';
import 'package:zombiejox/state/weights.dart';
import 'package:zombiejox/widgets/dumbbell_card.dart';
import 'package:zombiejox/widgets/failed_device_card.dart';
import 'package:zombiejox/widgets/weight_button.dart';

/// Connects-instantly fake Dumbbell that lets a test push state values
/// for assertions. Mirrors the shape used by `weight_group_test.dart`
/// but lives here so the home-screen tests are self-contained.
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
  bool failReconnect = false;
  int reconnectCallCount = 0;
  bool disconnectCalled = false;
  bool _ready = false;

  @override
  bool get isReady => !disconnectCalled && _ready;

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
    // Mirror the real Dumbbell: `isReady` doesn't flip true on connect
    // alone — only once a state frame arrives. Tests that need a ready
    // member call [emitState].
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
    disconnectCalled = true;
    if (!_states.isClosed) await _states.close();
    if (!_conn.isClosed) await _conn.close();
  }

  @override
  void handleTransportDrop() {
    _last = null;
    _ready = false;
  }

  @override
  Future<void> reconnect() async {
    reconnectCallCount++;
    if (failReconnect) throw StateError('fake reconnect failure');
    _conn.add(BleConnectionState.connected);
  }

  /// Simulate a mid-session BLE drop after the dumbbell has been ready.
  /// Mirrors the production [Dumbbell.handleTransportDrop] reset.
  void simulateDrop() {
    _last = null;
    _ready = false;
    _conn.add(BleConnectionState.disconnected);
  }

  void emitState(DumbbellState s) {
    _last = s;
    _ready = true;
    _states.add(s);
  }
}

/// In-memory [BleScanner] that lets tests push results without touching
/// `flutter_blue_plus`.
class _FakeScanner implements BleScanner {
  final _results = StreamController<List<ScanHit>>.broadcast();
  final _isScanning = StreamController<bool>.broadcast();
  // Replay-on-listen for adapterState so subscribers added after the
  // initial event still see the current value — mirrors how the
  // production stream behaves (FlutterBluePlus.adapterState replays).
  BleAdapterState _adapter = BleAdapterState.on;
  final _adapterStateController = StreamController<BleAdapterState>.broadcast();
  bool _scanning = false;

  @override
  bool get isScanningNow => _scanning;

  @override
  Stream<bool> get isScanning => _isScanning.stream;

  @override
  Stream<List<ScanHit>> get results => _results.stream;

  @override
  Stream<BleAdapterState> get adapterState async* {
    yield _adapter;
    yield* _adapterStateController.stream;
  }

  @override
  Future<void> startScan({
    List<String> withKeywords = const [],
    Duration? timeout,
  }) async {
    _scanning = true;
    _isScanning.add(true);
  }

  @override
  Future<void> stopScan() async {
    _scanning = false;
    _isScanning.add(false);
  }

  int turnOnBluetoothCalls = 0;
  bool turnOnBluetoothResult = true;

  @override
  Future<bool> turnOnBluetooth() async {
    turnOnBluetoothCalls++;
    return turnOnBluetoothResult;
  }

  void emit(List<ScanHit> hits) => _results.add(hits);

  /// Drive the adapter-state stream from tests — covers the "BT off
  /// mid-session" + "BT comes back on" transitions.
  void emitAdapterState(BleAdapterState s) {
    _adapter = s;
    _adapterStateController.add(s);
  }

  Future<void> dispose() async {
    await _results.close();
    await _isScanning.close();
    await _adapterStateController.close();
  }
}

DeviceRef _device(String id, {String name = ''}) =>
    DeviceRef(id: id, name: name);

ScanHit _hit(String id, String name, {int rssi = -60}) =>
    ScanHit(device: _device(id, name: name), rssi: rssi);

Future<Preferences> _freshPrefs({
  String unit = 'lbs',
  List<String> remembered = const [],
  bool explicit = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'units': unit,
    'unit_explicitly_chosen': explicit,
    'remembered_device_ids': remembered,
  });
  return Preferences.load();
}

/// Convenience: pump HomeScreen with stub seams and skip the
/// permission-grant blocker.
Future<({_FakeScanner scanner, List<_FakeDumbbell> fakes})> _pumpHome(
  WidgetTester tester, {
  required Preferences prefs,
  bool failConnect = false,
}) async {
  final scanner = _FakeScanner();
  addTearDown(scanner.dispose);
  final fakes = <_FakeDumbbell>[];
  await tester.pumpWidget(MaterialApp(
    home: HomeScreen(
      preferences: prefs,
      checkPermissionsGranted: () async => true,
      scanner: scanner,
      createWeightGroup: () => WeightGroup(newDumbbell: (d) {
        final f = _FakeDumbbell(d)..failConnect = failConnect;
        fakes.add(f);
        return f;
      }),
    ),
  ));
  // Resolve the async permission check + initial scan kickoff.
  await tester.pumpAndSettle();
  return (scanner: scanner, fakes: fakes);
}

void main() {
  testWidgets(
      'no remembered IDs → top region shows the "Tap a dumbbell below" hint',
      (tester) async {
    final prefs = await _freshPrefs();
    await _pumpHome(tester, prefs: prefs);

    expect(find.text('Tap a dumbbell below to connect'), findsOneWidget);
    expect(find.byType(DumbbellCard), findsNothing);
    expect(find.byType(FailedDeviceCard), findsNothing);
  });

  testWidgets(
      'weight grid renders all 8 buttons and is disabled when no member is ready',
      (tester) async {
    final prefs = await _freshPrefs();
    await _pumpHome(tester, prefs: prefs);

    final buttons =
        tester.widgetList<WeightButton>(find.byType(WeightButton)).toList();
    expect(buttons, hasLength(8));
    for (final b in buttons) {
      expect(b.onPressed, isNull,
          reason: 'no member ready → every weight button disabled');
    }
  });

  testWidgets(
      'warm-start: remembered IDs seed the top region in `connecting` state '
      'and the scanner starts in parallel', (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01', 'AA:02']);
    final ctx = await _pumpHome(tester, prefs: prefs);

    expect(ctx.fakes, hasLength(2),
        reason: 'WeightGroup.add() ran for each remembered id');
    expect(find.byType(DumbbellCard), findsNWidgets(2));
    expect(ctx.scanner.isScanningNow, isTrue,
        reason: 'scanner starts in parallel with the warm-start adds');
    // Hint must NOT appear once devices are seeded.
    expect(find.text('Tap a dumbbell below to connect'), findsNothing);
  });

  testWidgets(
      'promote-on-tap: tapping a scan-result card moves it into the top '
      'region and kicks off WeightGroup.add immediately', (tester) async {
    final prefs = await _freshPrefs();
    final ctx = await _pumpHome(tester, prefs: prefs);

    // Push one scan hit.
    ctx.scanner.emit([_hit('AA:01', 'DB200-01')]);
    await tester.pumpAndSettle();

    // Scan card visible, tap it.
    expect(find.text('DB200-01'), findsOneWidget);
    expect(ctx.fakes, isEmpty);
    await tester.tap(find.text('DB200-01'));
    await tester.pumpAndSettle();

    // Top card now rendered (connecting). Bottom scan card filters out
    // a device that's already in the selected list.
    expect(ctx.fakes, hasLength(1),
        reason: 'tap must trigger WeightGroup.add for the device');
    expect(find.byType(DumbbellCard), findsOneWidget);
  });

  testWidgets(
      'scan results filter out devices already in the top region '
      '— promoted devices do NOT re-appear in the bottom list', (tester) async {
    final prefs = await _freshPrefs();
    final ctx = await _pumpHome(tester, prefs: prefs);

    ctx.scanner.emit([
      _hit('AA:01', 'DB200-01'),
      _hit('AA:02', 'DB200-02'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('DB200-01'), findsOneWidget);
    expect(find.text('DB200-02'), findsOneWidget);

    // Tap one — it should leave the bottom list and appear only in the
    // top region.
    await tester.tap(find.text('DB200-01'));
    // Re-emit the same scan results (real scanners keep the hit
    // around).
    ctx.scanner.emit([
      _hit('AA:01', 'DB200-01'),
      _hit('AA:02', 'DB200-02'),
    ]);
    await tester.pumpAndSettle();

    // DB200-01 now lives in the top region (DumbbellCard renders the
    // device.displayName from DeviceRef, which is the id when name is
    // empty — but the scan filter is what matters here).
    expect(find.text('DB200-02'), findsOneWidget,
        reason: 'remaining un-promoted device stays in the bottom list');
  });

  testWidgets(
      'connect failure → FailedDeviceCard at the matching slot; retry '
      'cycles back to connected', (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01']);
    // First attempt fails, second succeeds.
    var attempt = 0;
    final scanner = _FakeScanner();
    addTearDown(scanner.dispose);
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        preferences: prefs,
        checkPermissionsGranted: () async => true,
        scanner: scanner,
        createWeightGroup: () => WeightGroup(newDumbbell: (d) {
          attempt++;
          return _FakeDumbbell(d)..failConnect = (attempt == 1);
        }),
      ),
    ));
    await tester.pumpAndSettle();

    // Warm-start populated 1 device; first connect failed.
    expect(find.byType(FailedDeviceCard), findsOneWidget);
    expect(find.byType(DumbbellCard), findsNothing);

    // Tap retry on the failed card. There's also a refresh icon in the
    // scan header (for rescanning), so scope the finder to the
    // FailedDeviceCard subtree.
    await tester.tap(find.descendant(
      of: find.byType(FailedDeviceCard),
      matching: find.byIcon(Icons.refresh),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(FailedDeviceCard), findsNothing);
    expect(find.byType(DumbbellCard), findsOneWidget);
  });

  testWidgets(
      'remove × on a connected card disconnects + drops the slot from the '
      'top region', (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01']);
    final ctx = await _pumpHome(tester, prefs: prefs);
    expect(ctx.fakes, hasLength(1));
    expect(find.byType(DumbbellCard), findsOneWidget);

    // The × on the connected card.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(DumbbellCard), findsNothing);
    expect(ctx.fakes.single.disconnectCalled, isTrue,
        reason: '× must call Dumbbell.disconnect on the underlying member');
    // Hint comes back once the top region is empty.
    expect(find.text('Tap a dumbbell below to connect'), findsOneWidget);
  });

  testWidgets(
      'weight buttons enable as soon as ANY member is ready; tap fans out '
      'only to ready members', (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01', 'AA:02']);
    final ctx = await _pumpHome(tester, prefs: prefs);
    expect(ctx.fakes, hasLength(2));

    // Bring one fake ready (the other stays "stuck connecting").
    ctx.fakes[0].emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();

    final buttons =
        tester.widgetList<WeightButton>(find.byType(WeightButton)).toList();
    final enabled = buttons.where((b) => b.onPressed != null).length;
    expect(enabled, 8,
        reason: 'one ready ⇒ all buttons enabled; offline mate ignored');

    await tester.tap(find.text('14 lbs'));
    await tester.pumpAndSettle();
    expect(ctx.fakes[0].setWeightCalls, [1]);
    expect(ctx.fakes[1].setWeightCalls, isEmpty,
        reason: 'not-ready member must not receive the set-weight call');
  });

  testWidgets('motor-active disables the weight grid', (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01']);
    final ctx = await _pumpHome(tester, prefs: prefs);
    ctx.fakes.single.emitState(
      const DumbbellState(weightIndex: 2, motorActive: true, batteryPct: 80),
    );
    await tester.pumpAndSettle();

    final buttons =
        tester.widgetList<WeightButton>(find.byType(WeightButton)).toList();
    for (final b in buttons) {
      expect(b.onPressed, isNull,
          reason: 'motor active ⇒ every button disabled mid-transition');
    }
  });

  testWidgets(
      'consensus index lights up the matching tile (selected flag) when '
      'every ready member agrees', (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01', 'AA:02']);
    final ctx = await _pumpHome(tester, prefs: prefs);
    for (final f in ctx.fakes) {
      f.emitState(
        const DumbbellState(weightIndex: 3, motorActive: false, batteryPct: 80),
      );
    }
    await tester.pumpAndSettle();

    final buttons =
        tester.widgetList<WeightButton>(find.byType(WeightButton)).toList();
    expect(buttons[3].selected, isTrue,
        reason: 'consensus on index 3 ⇒ that tile renders selected');
    for (var i = 0; i < buttons.length; i++) {
      if (i != 3) expect(buttons[i].selected, isFalse);
    }
  });

  testWidgets('failing set-weight surfaces a SnackBar (not an uncaught error)',
      (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01']);
    final ctx = await _pumpHome(tester, prefs: prefs);
    ctx.fakes.single.emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    ctx.fakes.single.failSetWeight = true;

    await tester.tap(find.text('20 lbs'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Failed to set weight'), findsOneWidget);
  });

  testWidgets('toggling units re-labels every weight button live',
      (tester) async {
    final prefs = await _freshPrefs(unit: 'lbs', explicit: true);
    await _pumpHome(tester, prefs: prefs);

    expect(find.text('8 lbs'), findsOneWidget);
    expect(find.text('3.6 kg'), findsNothing);

    // Flip the preference — bypassing the Settings screen since this
    // test is about HomeScreen's live re-render via
    // ValueListenableBuilder.
    await prefs.setUnit(WeightUnit.kg);
    await tester.pumpAndSettle();

    expect(find.text('3.6 kg'), findsOneWidget);
    expect(find.text('8 lbs'), findsNothing);
  });

  testWidgets(
      'auto-match-from-dock: both members agree on kg + user has not chosen '
      '→ app set to kg + SnackBar shown', (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01', 'AA:02']);
    final ctx = await _pumpHome(tester, prefs: prefs);
    for (final f in ctx.fakes) {
      f.emitState(const DumbbellState(
        weightIndex: 0,
        motorActive: false,
        batteryPct: 80,
        unitRaw: 0x01, // kg
      ));
    }
    // Both ready ⇒ "all accounted for" fires immediately — no debounce wait.
    await tester.pumpAndSettle();

    expect(prefs.unit.value, WeightUnit.kg);
    expect(find.textContaining('Unit set to kg'), findsOneWidget);
  });

  testWidgets(
      'persisted device set: after first verified connect, promote-on-tap '
      'updates rememberedDeviceIds', (tester) async {
    final prefs = await _freshPrefs(remembered: ['AA:01']);
    final ctx = await _pumpHome(tester, prefs: prefs);
    expect(prefs.rememberedDeviceIds, ['AA:01']);

    // First member becomes ready → onAnyConnected fires.
    ctx.fakes.single.emitState(
      const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
    );
    await tester.pumpAndSettle();
    expect(prefs.rememberedDeviceIds, ['AA:01'],
        reason: 'still one device after the verified connect');

    // Promote a second from the scan list.
    ctx.scanner.emit([_hit('AA:02', 'DB200-02')]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('DB200-02'));
    await tester.pumpAndSettle();

    expect(prefs.rememberedDeviceIds, ['AA:01', 'AA:02'],
        reason: 'post-verification promote-on-tap updates the remembered set');
  });

  testWidgets(
      'persisted device set: a Connect that never reaches ready does NOT '
      'poison rememberedDeviceIds', (tester) async {
    SharedPreferences.setMockInitialValues({
      'units': 'lbs',
      'remembered_device_ids': const <String>[],
    });
    final prefs = await Preferences.load();
    final scanner = _FakeScanner();
    addTearDown(scanner.dispose);

    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        preferences: prefs,
        checkPermissionsGranted: () async => true,
        scanner: scanner,
        createWeightGroup: () => WeightGroup(
          newDumbbell: (d) => _FakeDumbbell(d)..failConnect = true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    scanner.emit([_hit('AA:01', 'DB200-01')]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('DB200-01'));
    await tester.pumpAndSettle();

    expect(find.byType(FailedDeviceCard), findsOneWidget);
    expect(prefs.rememberedDeviceIds, isEmpty,
        reason:
            'no member ever reached ready ⇒ remembered set must not be written');
  });

  group('§2b UX polish', () {
    testWidgets(
        'tapping a weight fires `HapticFeedback.selectionClick` before '
        'the BLE write resolves', (tester) async {
      // Intercept calls on the platform channel. `HapticFeedback`
      // marshals through `flutter/platform` with method name
      // `HapticFeedback.vibrate` and an enum-name string argument.
      final hapticCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            hapticCalls.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                SystemChannels.platform,
                null,
              ));

      final prefs = await _freshPrefs(remembered: ['AA:01']);
      final ctx = await _pumpHome(tester, prefs: prefs);
      ctx.fakes.single.emitState(
        const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('20 lbs'));
      await tester.pumpAndSettle();

      expect(hapticCalls, contains('HapticFeedbackType.selectionClick'),
          reason: 'tap-to-set-weight ⇒ canonical selection haptic');
      expect(ctx.fakes.single.setWeightCalls, [2],
          reason: 'and the BLE write still goes through');
    });

    testWidgets(
        'first reconnect-attempt failure surfaces a one-shot SnackBar; '
        'subsequent failures stay silent (the card UI carries the rest)',
        (tester) async {
      final prefs = await _freshPrefs(remembered: ['AA:01']);
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);
      final fakes = <_FakeDumbbell>[];
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => true,
          scanner: scanner,
          createWeightGroup: () => WeightGroup(newDumbbell: (d) {
            final f = _FakeDumbbell(d)..failReconnect = true;
            fakes.add(f);
            return f;
          }),
        ),
      ));
      await tester.pumpAndSettle();
      fakes.single.emitState(
        const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
      );
      await tester.pumpAndSettle();

      // Drop → supervisor's immediate first attempt runs (and fails,
      // because failReconnect=true) → attempt counter bumps to 1.
      fakes.single.simulateDrop();
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget,
          reason: 'first attempt failure ⇒ one SnackBar');
      expect(find.textContaining('retrying in the background'), findsOneWidget);
    });

    testWidgets(
        'reconnect-failure SnackBar is suppressed for subsequent retries '
        'within the same drop incident', (tester) async {
      // After the first failure surfaced a SnackBar, further failures
      // for the SAME device + SAME drop must NOT re-surface another —
      // the card's "Reconnecting…" chip already conveys ongoing
      // activity; spamming SnackBars would be noisy.
      final prefs = await _freshPrefs(remembered: ['AA:01']);
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);
      final fakes = <_FakeDumbbell>[];
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => true,
          scanner: scanner,
          createWeightGroup: () => WeightGroup(newDumbbell: (d) {
            final f = _FakeDumbbell(d)..failReconnect = true;
            fakes.add(f);
            return f;
          }),
        ),
      ));
      await tester.pumpAndSettle();
      fakes.single.emitState(
        const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
      );
      await tester.pumpAndSettle();

      fakes.single.simulateDrop();
      await tester.pumpAndSettle();
      // First SnackBar appeared. Clear it by tapping elsewhere or
      // letting it time out — but tests can just check that no
      // additional SnackBar appears after another failed attempt by
      // forcing the scanner-toggle-on event to kick reconnect again.
      // (Actually `kickReconnectsForResume` from the adapter handler
      // re-fires the attempt; a fresh failure should NOT re-show.)
      scanner.emitAdapterState(BleAdapterState.off);
      await tester.pumpAndSettle();
      scanner.emitAdapterState(BleAdapterState.on);
      await tester.pumpAndSettle();

      // Only the original SnackBar; no second one queued behind it.
      expect(find.byType(SnackBar), findsOneWidget,
          reason: 'subsequent failures for same drop must stay silent');
    });
  });

  testWidgets('stop / refresh icon toggles the scanner', (tester) async {
    final prefs = await _freshPrefs();
    final ctx = await _pumpHome(tester, prefs: prefs);
    expect(ctx.scanner.isScanningNow, isTrue);

    // Scope to the scan header — when the scanner stops with no
    // results, the empty-state UI surfaces its own "Scan again" button
    // and `find.byTooltip` would otherwise be ambiguous.
    await tester.tap(find.byTooltip('Stop scanning'));
    await tester.pumpAndSettle();
    expect(ctx.scanner.isScanningNow, isFalse);

    await tester.tap(find.byTooltip('Scan again'));
    await tester.pumpAndSettle();
    expect(ctx.scanner.isScanningNow, isTrue);
  });

  group('edge cases — §1h', () {
    // A. BT adapter state — banner replaces the scan placeholder when
    // the radio isn't usable, surfaces an "Open Settings" button.
    testWidgets(
        'adapter state: BT off on Android → banner + "Enable Bluetooth" '
        'CTA that triggers `scanner.turnOnBluetooth` (in-app system '
        'prompt, no app-settings detour)', (tester) async {
      // Pin the target platform so a future Flutter change to the
      // widget-test default doesn't silently shift this test. Reset
      // inside the test body (not via addTearDown): the framework's
      // invariant check fires before tearDowns run.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final prefs = await _freshPrefs();
        final ctx = await _pumpHome(tester, prefs: prefs);

        // Initial state: adapter is on, no banner.
        expect(find.textContaining('Bluetooth is off'), findsNothing);

        ctx.scanner.emitAdapterState(BleAdapterState.off);
        await tester.pumpAndSettle();

        expect(find.textContaining('Bluetooth is off'), findsOneWidget);
        expect(find.text('Enable Bluetooth'), findsOneWidget,
            reason: 'Android off-state CTA pops the in-app enable prompt');
        expect(find.text('Open Settings'), findsNothing,
            reason: 'off-state must NOT route to app settings');
        expect(find.text('Turn Bluetooth on to scan.'), findsOneWidget,
            reason: 'scan-area copy is consistent with the banner');

        await tester.tap(find.text('Enable Bluetooth'));
        await tester.pumpAndSettle();
        expect(ctx.scanner.turnOnBluetoothCalls, 1,
            reason: 'CTA must call scanner.turnOnBluetooth');

        // Bringing BT back on hides both the banner and the "off" copy.
        ctx.scanner.emitAdapterState(BleAdapterState.on);
        await tester.pumpAndSettle();
        expect(find.textContaining('Bluetooth is off'), findsNothing);
        expect(find.text('Turn Bluetooth on to scan.'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'adapter state: BT off on iOS → banner shows instructional text '
        '(no programmatic CTA — iOS doesn\'t expose a toggle)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final prefs = await _freshPrefs();
        final ctx = await _pumpHome(tester, prefs: prefs);
        ctx.scanner.emitAdapterState(BleAdapterState.off);
        await tester.pumpAndSettle();

        expect(find.textContaining('Bluetooth is off'), findsOneWidget);
        expect(find.text('Enable Bluetooth'), findsNothing,
            reason: 'iOS has no programmatic BT toggle — hide the CTA');
        expect(find.text('Open Settings'), findsNothing,
            reason: 'app settings is for permission issues, not BT-off');
        expect(
            find.textContaining('Settings or Control Center'), findsOneWidget,
            reason: 'iOS instructional copy points the user to the OS');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'adapter state: unsupported → distinct banner copy (terminal '
        'platform state, not a "turn it on" prompt). Open Settings '
        'button is suppressed (nothing in Settings will surface a '
        'missing BLE radio).', (tester) async {
      final prefs = await _freshPrefs();
      final ctx = await _pumpHome(tester, prefs: prefs);
      ctx.scanner.emitAdapterState(BleAdapterState.unsupported);
      await tester.pumpAndSettle();

      expect(find.textContaining('Bluetooth Low Energy is not available'),
          findsOneWidget);
      expect(find.text('Open Settings'), findsNothing);
      // Scan-area copy is tailored too — NOT "turn it on".
      expect(
          find.text('Scanning is unavailable on this device.'), findsOneWidget);
      expect(find.text('Turn Bluetooth on to scan.'), findsNothing);
    });

    testWidgets(
        'adapter state: unauthorized → distinct "permission denied" '
        'banner (not the "off" or "unsupported" wording)', (tester) async {
      final prefs = await _freshPrefs();
      final ctx = await _pumpHome(tester, prefs: prefs);
      ctx.scanner.emitAdapterState(BleAdapterState.unauthorized);
      await tester.pumpAndSettle();

      expect(find.textContaining('Bluetooth permission was denied'),
          findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.text('Grant Bluetooth permission to scan.'), findsOneWidget);
    });

    // B. Permission revoked mid-session — on AppLifecycleState.resumed,
    // re-check; if revoked, push back to PermissionScreen.
    testWidgets(
        'permission revoked while backgrounded → on resume, '
        'pushReplacement to PermissionScreen', (tester) async {
      final prefs = await _freshPrefs();
      // Start with permissions granted, then flip the seam to revoked
      // before pushing the lifecycle event so the resume re-check sees
      // the new value.
      var granted = true;
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);

      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => granted,
          scanner: scanner,
          createWeightGroup: () => WeightGroup(
            newDumbbell: (d) => _FakeDumbbell(d),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);

      // Simulate Settings-app revocation.
      granted = false;
      // didChangeAppLifecycleState fires from the framework; trigger
      // the inactive→resumed sequence so the observer runs.
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();

      // PermissionScreen replaced the route. HomeScreen is gone.
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(PermissionScreen), findsOneWidget);
    });

    // C. All-out-of-range → empty-state hint + Scan again button.
    testWidgets(
        'scan ends with no results → "No JaxJox dumbbells found" hint '
        'and a Scan again button that restarts the scanner', (tester) async {
      final prefs = await _freshPrefs();
      final ctx = await _pumpHome(tester, prefs: prefs);
      expect(ctx.scanner.isScanningNow, isTrue);

      // Scanner stops with no hits.
      await ctx.scanner.stopScan();
      await tester.pumpAndSettle();

      expect(find.text('No JaxJox dumbbells found.'), findsOneWidget);
      expect(find.textContaining('powered on and in range'), findsOneWidget);

      // The in-place "Scan again" button — distinct from the toolbar
      // refresh icon (which has tooltip 'Scan again' too).
      await tester.tap(find.widgetWithText(FilledButton, 'Scan again'));
      await tester.pumpAndSettle();
      expect(ctx.scanner.isScanningNow, isTrue);
    });

    testWidgets(
        'scan running with no results yet → "Scanning…" placeholder '
        '(not the No-results hint)', (tester) async {
      final prefs = await _freshPrefs();
      await _pumpHome(tester, prefs: prefs);

      expect(find.text('Scanning for JaxJox devices…'), findsOneWidget);
      expect(find.text('No JaxJox dumbbells found.'), findsNothing);
    });
  });

  group('rename (§2e)', () {
    testWidgets(
        'tap name on a connected card → dialog → OK persists the custom '
        'name to Preferences AND the card re-renders with it',
        (tester) async {
      final prefs = await _freshPrefs(remembered: ['AA:01']);
      final ctx = await _pumpHome(tester, prefs: prefs);
      ctx.fakes.single.emitState(
        const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
      );
      await tester.pumpAndSettle();

      // Card shows the raw id (no advertised name on the remembered
      // entry, no custom name yet).
      expect(find.text('AA:01'), findsOneWidget);

      await tester.tap(find.text('AA:01'));
      await tester.pumpAndSettle();
      expect(find.text('Rename dumbbell'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Left');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Left'), findsOneWidget,
          reason: 'card re-renders with the new name');
      expect(find.text('AA:01'), findsNothing,
          reason: 'raw id is hidden once the custom name takes over');
      expect(prefs.customDeviceNames, {'AA:01': 'Left'},
          reason: 'rename persists immediately, independent of verified-set');
    });

    testWidgets(
        'a scan-list device that was renamed in a prior session shows '
        'the user\'s name (looked up via SelectionModel.displayNameFor)',
        (tester) async {
      // Fresh launch with no remembered devices, but with a saved
      // custom name for AA:01 from an earlier session. The device
      // appears in the scan list (with an advertised name that passes
      // `isJaxJoxLiveDeviceName`) — should render as "Left", not the
      // advertised name or the raw id.
      SharedPreferences.setMockInitialValues({
        'units': 'lbs',
        'remembered_device_ids': const <String>[],
        'custom_device_names': '{"AA:01":"Left"}',
      });
      final prefs = await Preferences.load();
      final ctx = await _pumpHome(tester, prefs: prefs);

      ctx.scanner.emit([_hit('AA:01', 'DB200-AA01')]);
      await tester.pumpAndSettle();

      expect(find.text('Left'), findsOneWidget,
          reason: 'scan list reflects the saved custom name');
      expect(find.text('DB200-AA01'), findsNothing,
          reason: 'advertised name is hidden by the user-chosen name');
    });
  });

  group('reconnect (§2a)', () {
    testWidgets(
        'mid-session drop on a ready dumbbell → card renders '
        '"Reconnecting…" (driven by snapshot.retryStates)', (tester) async {
      final prefs = await _freshPrefs(remembered: ['AA:01']);
      final ctx = await _pumpHome(tester, prefs: prefs);
      ctx.fakes.single.emitState(
        const DumbbellState(weightIndex: 2, motorActive: false, batteryPct: 80),
      );
      await tester.pumpAndSettle();

      ctx.fakes.single.simulateDrop();
      await tester.pumpAndSettle();

      // Status chip and body line both say "Reconnecting" / "Reconnecting…".
      expect(find.text('Reconnecting…'), findsOneWidget,
          reason: 'snapshot.retryStates ⇒ Reconnecting body line');
      expect(find.text('Reconnecting'), findsOneWidget,
          reason: 'and the status chip');
      expect(find.text('Disconnected'), findsNothing,
          reason: 'retryState preempts the bare Disconnected fallback');
      // reconnect() was called by the supervisor's immediate first attempt.
      expect(ctx.fakes.single.reconnectCallCount, greaterThanOrEqualTo(1));
    });

    testWidgets(
        'AppLifecycleState.resumed with permissions granted: '
        'kickReconnectsForResume fast-forwards a waiting reconnect',
        (tester) async {
      // failReconnect=true so the immediate attempt fails and the
      // supervisor enters a 2s wait; the resume kick should
      // fast-forward that wait.
      final prefs = await _freshPrefs(remembered: ['AA:01']);
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);
      final fakes = <_FakeDumbbell>[];

      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => true,
          scanner: scanner,
          createWeightGroup: () => WeightGroup(newDumbbell: (d) {
            final f = _FakeDumbbell(d)..failReconnect = true;
            fakes.add(f);
            return f;
          }),
        ),
      ));
      await tester.pumpAndSettle();

      fakes.single.emitState(
        const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
      );
      await tester.pumpAndSettle();

      fakes.single.simulateDrop();
      await tester.pumpAndSettle();
      expect(fakes.single.reconnectCallCount, 1,
          reason: 'immediate first attempt fired');

      // Simulate resume.
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();

      expect(fakes.single.reconnectCallCount, 2,
          reason: 'resume kick fast-forwarded the waiting timer');
    });

    testWidgets(
        'BleAdapterState transition off → on fast-forwards a waiting '
        'reconnect (BT toggled off then on, app stays foregrounded)',
        (tester) async {
      // Without this, retries that climbed to the 60s cap while BT was
      // off would keep the user on "Reconnecting…" for up to a minute
      // after they flip BT back on. The lifecycle-resume kick doesn't
      // help — the app never backgrounds.
      final prefs = await _freshPrefs(remembered: ['AA:01']);
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);
      final fakes = <_FakeDumbbell>[];

      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => true,
          scanner: scanner,
          createWeightGroup: () => WeightGroup(newDumbbell: (d) {
            final f = _FakeDumbbell(d)..failReconnect = true;
            fakes.add(f);
            return f;
          }),
        ),
      ));
      await tester.pumpAndSettle();
      fakes.single.emitState(
        const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
      );
      await tester.pumpAndSettle();

      // BT goes off: supervisor sees the drop, schedules the immediate
      // first attempt (which fails because BT is off), then waits at 2s.
      fakes.single.simulateDrop();
      await tester.pumpAndSettle();
      expect(fakes.single.reconnectCallCount, 1,
          reason: 'immediate first attempt fired');

      // The "BT is off" banner state.
      scanner.emitAdapterState(BleAdapterState.off);
      await tester.pumpAndSettle();

      // BT comes back on → kick fires immediately, no 2s wait.
      scanner.emitAdapterState(BleAdapterState.on);
      await tester.pumpAndSettle();

      expect(fakes.single.reconnectCallCount, 2,
          reason: 'BT-on transition must fast-forward the waiting timer');
    });

    testWidgets(
        'AppLifecycleState.resumed with permissions revoked: routes to '
        'PermissionScreen AND does NOT call reconnect', (tester) async {
      final prefs = await _freshPrefs(remembered: ['AA:01']);
      var granted = true;
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);
      final fakes = <_FakeDumbbell>[];

      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => granted,
          scanner: scanner,
          createWeightGroup: () => WeightGroup(newDumbbell: (d) {
            final f = _FakeDumbbell(d)..failReconnect = true;
            fakes.add(f);
            return f;
          }),
        ),
      ));
      await tester.pumpAndSettle();
      fakes.single.emitState(
        const DumbbellState(weightIndex: 0, motorActive: false, batteryPct: 80),
      );
      await tester.pumpAndSettle();
      fakes.single.simulateDrop();
      await tester.pumpAndSettle();
      expect(fakes.single.reconnectCallCount, 1);
      final beforeResume = fakes.single.reconnectCallCount;

      // Revoke + resume.
      granted = false;
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();

      expect(find.byType(PermissionScreen), findsOneWidget);
      expect(fakes.single.reconnectCallCount, beforeResume,
          reason: 'revoked permissions ⇒ no extra reconnect attempts');
    });
  });
}
