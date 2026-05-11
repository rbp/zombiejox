import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/widgets/failed_device_card.dart';

BluetoothDevice _device(String id) =>
    BluetoothDevice(remoteId: DeviceIdentifier(id));

Future<void> _pump(WidgetTester tester, Widget w) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
}

void main() {
  testWidgets('renders the device name and a "Failed to connect" status',
      (tester) async {
    await _pump(
      tester,
      FailedDeviceCard(
        device: _device('AA:01'),
        error: StateError('boom'),
        onRetry: () {},
      ),
    );
    // The device name (from advName, falling back to the remote id).
    expect(find.text('AA:01'), findsOneWidget);
    expect(find.text('Failed to connect'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('the status text uses the theme error colour', (tester) async {
    final theme = ThemeData(
      colorScheme: const ColorScheme.light(error: Color(0xFFFF1234)),
    );
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: FailedDeviceCard(
          device: _device('AA:01'),
          onRetry: () {},
        ),
      ),
    ));

    final statusText = tester.widget<Text>(find.text('Failed to connect'));
    expect(statusText.style?.color, theme.colorScheme.error);
  });

  testWidgets('tapping refresh fires onRetry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      FailedDeviceCard(
        device: _device('AA:01'),
        onRetry: () => retries++,
      ),
    );
    await tester.tap(find.byIcon(Icons.refresh));
    expect(retries, 1);
  });

  testWidgets('null onRetry disables the refresh button', (tester) async {
    await _pump(
      tester,
      FailedDeviceCard(device: _device('AA:01')),
    );
    final btn = tester.widget<IconButton>(find.byType(IconButton));
    expect(btn.onPressed, isNull);
  });

  testWidgets('error is included in the refresh button tooltip',
      (tester) async {
    await _pump(
      tester,
      FailedDeviceCard(
        device: _device('AA:01'),
        error: 'connection timed out',
        onRetry: () {},
      ),
    );
    final btn = tester.widget<IconButton>(find.byType(IconButton));
    expect(btn.tooltip, contains('connection timed out'));
  });
}
