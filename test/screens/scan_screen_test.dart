import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/screens/scan_screen.dart';

BluetoothDevice _device(String id) =>
    BluetoothDevice(remoteId: DeviceIdentifier(id));

ScanResult _result(String id, String name, {int rssi = -60}) {
  return ScanResult(
    device: _device(id),
    advertisementData: AdvertisementData(
      advName: name,
      txPowerLevel: null,
      appearance: null,
      connectable: true,
      manufacturerData: const {},
      serviceData: const {},
      serviceUuids: const [],
    ),
    rssi: rssi,
    timeStamp: DateTime.now(),
  );
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
        selected: <BluetoothDevice>{},
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
          _result('AA:01', 'DB200-0161997'),
          _result('AA:02', 'DB200-0161998'),
        ],
        selected: <BluetoothDevice>{},
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
    final dev1 = _device('AA:01');
    final dev2 = _device('AA:02');
    final results = [
      ScanResult(
        device: dev1,
        advertisementData: AdvertisementData(
          advName: 'DB200-A',
          txPowerLevel: null,
          appearance: null,
          connectable: true,
          manufacturerData: const {},
          serviceData: const {},
          serviceUuids: const [],
        ),
        rssi: -60,
        timeStamp: DateTime.now(),
      ),
      ScanResult(
        device: dev2,
        advertisementData: AdvertisementData(
          advName: 'DB200-B',
          txPowerLevel: null,
          appearance: null,
          connectable: true,
          manufacturerData: const {},
          serviceData: const {},
          serviceUuids: const [],
        ),
        rssi: -60,
        timeStamp: DateTime.now(),
      ),
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
    BluetoothDevice? toggled;
    final dev = _device('AA:01');
    await _pump(
      tester,
      ScanResultsList(
        results: [_result('AA:01', 'DB200-0161997')],
        selected: <BluetoothDevice>{},
        onToggle: (d) => toggled = d,
      ),
    );

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();

    expect(toggled, equals(dev));
  });
}
