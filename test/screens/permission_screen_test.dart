import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/screens/permission_screen.dart';
import 'package:zombiejox/state/preferences.dart';

Future<Preferences> _freshPrefs() async {
  SharedPreferences.setMockInitialValues({});
  return Preferences.load();
}

void main() {
  testWidgets('renders the rationale and a Continue button', (tester) async {
    final prefs = await _freshPrefs();
    await tester.pumpWidget(MaterialApp(
      home: PermissionScreen(
        preferences: prefs,
        requestPermissions: () async => true,
      ),
    ));

    expect(find.textContaining('ZombieJox needs Bluetooth'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    // Denied-state UI is not shown until the user taps Continue.
    expect(find.text('Open Settings'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('Continue + granted → calls onGranted', (tester) async {
    final prefs = await _freshPrefs();

    var onGrantedCalled = false;
    await tester.pumpWidget(MaterialApp(
      home: PermissionScreen(
        preferences: prefs,
        requestPermissions: () async => true,
        onGranted: (_) => onGrantedCalled = true,
      ),
    ));

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(onGrantedCalled, isTrue);
  });

  testWidgets('Continue + denied → shows the denied state', (tester) async {
    final prefs = await _freshPrefs();

    await tester.pumpWidget(MaterialApp(
      home: PermissionScreen(
        preferences: prefs,
        requestPermissions: () async => false,
      ),
    ));

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // PermissionScreen is still there, but in the denied state.
    expect(find.byType(PermissionScreen), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('Permission was denied'), findsOneWidget);
  });

  testWidgets('Try again → returns to the rationale state', (tester) async {
    final prefs = await _freshPrefs();
    await tester.pumpWidget(MaterialApp(
      home: PermissionScreen(
        preferences: prefs,
        requestPermissions: () async => false,
      ),
    ));

    // Get to the denied state.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);

    // Tap Try again — back to the initial rationale.
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
