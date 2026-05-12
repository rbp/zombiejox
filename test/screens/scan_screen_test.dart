import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/ble/ble_scanner.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/screens/scan_screen.dart';
import 'package:zombiejox/state/preferences.dart';

DeviceRef _device(String id, {String name = ''}) =>
    DeviceRef(id: id, name: name);

ScanHit _hit(String id, String name, {int rssi = -60}) =>
    ScanHit(device: _device(id, name: name), rssi: rssi);

/// In-memory [BleScanner] for ScanScreen tests that need the scan path to
/// not call FlutterBluePlus. Defaults to "idle / empty results"; tests can
/// push results via [emit] if they need to.
class _FakeScanner implements BleScanner {
  final _results = StreamController<List<ScanHit>>.broadcast();
  final _isScanning = StreamController<bool>.broadcast();
  bool _scanning = false;

  @override
  bool get isScanningNow => _scanning;

  @override
  Stream<bool> get isScanning => _isScanning.stream;

  @override
  Stream<List<ScanHit>> get results => _results.stream;

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

  Future<void> dispose() async {
    await _results.close();
    await _isScanning.close();
  }
}

Future<void> _pump(WidgetTester tester, Widget w) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
}

void main() {
  testWidgets('empty results show the "Scanning…" placeholder', (tester) async {
    await _pump(
      tester,
      ScanResultsList(
        results: const [],
        selected: <DeviceRef>{},
        onToggle: (_) {},
      ),
    );
    expect(find.textContaining('Scanning'), findsOneWidget);
  });

  testWidgets('renders one CheckboxListTile per result with advName + remoteId',
      (tester) async {
    await _pump(
      tester,
      ScanResultsList(
        results: [
          _hit('AA:01', 'DB200-0161997'),
          _hit('AA:02', 'DB200-0161998'),
        ],
        selected: <DeviceRef>{},
        onToggle: (_) {},
      ),
    );
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text('DB200-0161997'), findsOneWidget);
    expect(find.text('DB200-0161998'), findsOneWidget);
    expect(find.textContaining('AA:01'), findsOneWidget);
    expect(find.textContaining('AA:02'), findsOneWidget);
  });

  testWidgets('tile checkbox reflects whether the device is in `selected`',
      (tester) async {
    final dev1 = _device('AA:01', name: 'DB200-A');
    final dev2 = _device('AA:02', name: 'DB200-B');
    final results = [
      ScanHit(device: dev1, rssi: -60),
      ScanHit(device: dev2, rssi: -60),
    ];

    await _pump(
      tester,
      ScanResultsList(
        results: results,
        selected: {dev1},
        onToggle: (_) {},
      ),
    );

    final checkboxes = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(checkboxes, hasLength(2));
    expect(checkboxes[0].value, isTrue);
    expect(checkboxes[1].value, isFalse);
  });

  testWidgets('tapping a tile calls onToggle with the device', (tester) async {
    DeviceRef? toggled;
    final dev = _device('AA:01', name: 'DB200-0161997');
    await _pump(
      tester,
      ScanResultsList(
        results: [_hit('AA:01', 'DB200-0161997')],
        selected: <DeviceRef>{},
        onToggle: (d) => toggled = d,
      ),
    );

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();

    expect(toggled, equals(dev));
  });

  // ScanScreen-level (full widget) tests. These cover the cold-start
  // routing decision: remembered devices → auto-navigate to ControlScreen
  // and let it commit them post-connect; no remembered devices → fall
  // through to the scan UI. We inject the permission check + the
  // ControlScreen builder + a fake scanner so the test doesn't hit BLE /
  // permission platform channels.

  group('ScanScreen auto-connect routing', () {
    testWidgets(
        'remembered IDs + permissions granted → pushes the control route '
        'with the rehydrated devices in the saved order', (tester) async {
      SharedPreferences.setMockInitialValues({
        'units': 'lbs',
        'remembered_device_ids': ['AA:01', 'AA:02'],
      });
      final prefs = await Preferences.load();
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);

      List<DeviceRef>? capturedDevices;
      await tester.pumpWidget(MaterialApp(
        home: ScanScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => true,
          scanner: scanner,
          controlScreenBuilder: (ctx, devices, _) {
            capturedDevices = devices;
            return const Scaffold(body: Text('STUB CONTROL'));
          },
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('STUB CONTROL'), findsOneWidget);
      expect(capturedDevices, isNotNull);
      expect(capturedDevices!.map((d) => d.id).toList(), ['AA:01', 'AA:02']);
    });

    testWidgets(
        'the onAnyConnected callback handed to ControlScreen is the one '
        'that persists the remembered set (post-success, not pre-push)',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'units': 'lbs',
        'remembered_device_ids': ['AA:01'],
      });
      final prefs = await Preferences.load();
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);

      VoidCallback? capturedOnConnected;
      await tester.pumpWidget(MaterialApp(
        home: ScanScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => true,
          scanner: scanner,
          controlScreenBuilder: (ctx, devices, onAnyConnected) {
            capturedOnConnected = onAnyConnected;
            return const Scaffold(body: Text('STUB CONTROL'));
          },
        ),
      ));
      await tester.pumpAndSettle();

      // Wipe the persisted set so we can prove the callback is what
      // re-persists, not some earlier eager save.
      await prefs.setRememberedDeviceIds(const []);
      expect(prefs.rememberedDeviceIds, isEmpty);

      capturedOnConnected!();
      await tester.pumpAndSettle();
      expect(prefs.rememberedDeviceIds, ['AA:01']);
    });

    testWidgets(
        'sticky after pop: the auto-connect path fires once per cold start, '
        'not again when the user comes back via Disconnect-all',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'units': 'lbs',
        'remembered_device_ids': ['AA:01'],
      });
      final prefs = await Preferences.load();
      final scanner = _FakeScanner();
      addTearDown(scanner.dispose);

      var pushCount = 0;
      await tester.pumpWidget(MaterialApp(
        home: ScanScreen(
          preferences: prefs,
          checkPermissionsGranted: () async => true,
          scanner: scanner,
          controlScreenBuilder: (ctx, devices, _) {
            pushCount++;
            // Pop immediately so we land back on the scan screen and can
            // observe whether the routing fires a *second* time.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.of(ctx).pop();
            });
            return const Scaffold(body: Text('STUB CONTROL'));
          },
        ),
      ));
      await tester.pumpAndSettle();

      // The auto-connect routing must NOT re-fire after the pop. If it
      // did, pushCount would be > 1 (and we'd be in an infinite push/pop
      // loop).
      expect(pushCount, 1);
    });
  });
}
