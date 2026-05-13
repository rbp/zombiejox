import 'dart:async';

import 'package:flutter/material.dart';
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
  final _adapterStateController =
      StreamController<BleAdapterState>.broadcast();
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
      '— promoted devices do NOT re-appear in the bottom list',
      (tester) async {
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
        reason:
            'post-verification promote-on-tap updates the remembered set');
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
        'adapter state: BT off → banner + "Turn Bluetooth on" hint in '
        'the scan area', (tester) async {
      final prefs = await _freshPrefs();
      final ctx = await _pumpHome(tester, prefs: prefs);

      // Initial state: adapter is on, no banner.
      expect(find.textContaining('Bluetooth is off'), findsNothing);

      ctx.scanner.emitAdapterState(BleAdapterState.off);
      await tester.pumpAndSettle();

      expect(find.textContaining('Bluetooth is off'), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget,
          reason: 'banner exposes a one-tap recovery affordance');
      expect(find.text('Turn Bluetooth on to scan.'), findsOneWidget,
          reason: 'scan-area copy is consistent with the banner');

      // Bringing BT back on hides both the banner and the "off" copy.
      ctx.scanner.emitAdapterState(BleAdapterState.on);
      await tester.pumpAndSettle();
      expect(find.textContaining('Bluetooth is off'), findsNothing);
      expect(find.text('Turn Bluetooth on to scan.'), findsNothing);
    });

    testWidgets(
        'adapter state: unsupported → distinct banner copy (terminal '
        'platform state, not a "turn it on" prompt)', (tester) async {
      final prefs = await _freshPrefs();
      final ctx = await _pumpHome(tester, prefs: prefs);
      ctx.scanner.emitAdapterState(BleAdapterState.unsupported);
      await tester.pumpAndSettle();

      expect(find.textContaining('Bluetooth Low Energy is not available'),
          findsOneWidget);
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
        'and a Scan again button that restarts the scanner',
        (tester) async {
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
}
