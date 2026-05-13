import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/widgets/failed_device_card.dart';

DeviceRef _device(String id) => DeviceRef(id: id);

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
        onRemove: () {},
      ),
    );
    // The device name (from advName, falling back to the remote id).
    expect(find.text('AA:01'), findsOneWidget);
    expect(find.text('Failed to connect'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('tapping refresh fires onRetry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      FailedDeviceCard(
        device: _device('AA:01'),
        error: StateError('boom'),
        onRetry: () => retries++,
        onRemove: () {},
      ),
    );
    await tester.tap(find.byIcon(Icons.refresh));
    expect(retries, 1);
  });

  testWidgets('error is included in the refresh button tooltip',
      (tester) async {
    await _pump(
      tester,
      FailedDeviceCard(
        device: _device('AA:01'),
        error: 'connection timed out',
        onRetry: () {},
        onRemove: () {},
      ),
    );
    // Two IconButtons (refresh + close); scope the tooltip lookup to
    // the refresh one explicitly.
    final btn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.refresh),
        matching: find.byType(IconButton),
      ),
    );
    expect(btn.tooltip, contains('connection timed out'));
  });

  testWidgets('onRemove → × icon renders and tap fires the callback',
      (tester) async {
    var removes = 0;
    await _pump(
      tester,
      FailedDeviceCard(
        device: _device('AA:01'),
        error: StateError('boom'),
        onRetry: () {},
        onRemove: () => removes++,
      ),
    );
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    expect(removes, 1);
  });

  testWidgets(
      'displayName override (§2e) — when provided, replaces the raw '
      'device id shown on the card', (tester) async {
    await _pump(
      tester,
      FailedDeviceCard(
        device: _device('AA:01'),
        error: StateError('boom'),
        onRetry: () {},
        onRemove: () {},
        displayName: 'My Left',
      ),
    );
    expect(find.text('My Left'), findsOneWidget);
    expect(find.text('AA:01'), findsNothing);
  });

  testWidgets(
      'rename flow (§2e): tap the name → dialog → OK fires onRename '
      'with the entered string', (tester) async {
    final renames = <String>[];
    await _pump(
      tester,
      FailedDeviceCard(
        device: _device('AA:01'),
        error: StateError('boom'),
        onRetry: () {},
        onRemove: () {},
        displayName: 'AA:01',
        onRename: renames.add,
      ),
    );
    await tester.tap(find.text('AA:01'));
    await tester.pumpAndSettle();
    expect(find.text('Rename dumbbell'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Right');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(renames, ['Right']);
  });
}
