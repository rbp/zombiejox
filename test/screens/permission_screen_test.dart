import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
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

  testWidgets(
      'denied copy on iOS spells out the Settings breadcrumb '
      '(Settings → ZombieJox → Bluetooth) — the legacy root-level path '
      'is the one that works on iOS 16 (Apps section only exists on '
      'iOS 17+, and per-app entries still appear at the root there too)',
      (tester) async {
    // Reset inside the test body (not via addTearDown): the framework's
    // invariant check fires before tearDowns run.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final prefs = await _freshPrefs();
      await tester.pumpWidget(MaterialApp(
        home: PermissionScreen(
          preferences: prefs,
          requestPermissions: () async => false,
        ),
      ));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Settings → ZombieJox → Bluetooth'),
        findsOneWidget,
        reason: 'iOS deep-links to the app\'s Settings page; the breadcrumb '
            'tells the user which toggle to flip once they land there',
      );
      expect(find.textContaining('Nearby devices'), findsNothing,
          reason: 'Android-only breadcrumb must not leak onto iOS');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'denied copy on Android spells out the Settings breadcrumb '
      '(Settings → Apps → ZombieJox → Permissions → Nearby devices)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final prefs = await _freshPrefs();
      await tester.pumpWidget(MaterialApp(
        home: PermissionScreen(
          preferences: prefs,
          requestPermissions: () async => false,
        ),
      ));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nearby devices'), findsOneWidget,
          reason: 'Android puts the toggle under Permissions → Nearby devices');
      expect(find.textContaining('→ Bluetooth.'), findsNothing,
          reason: 'iOS-only breadcrumb tail must not leak onto Android');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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

  testWidgets(
      'a parent rebuild that swaps `requestPermissions` takes effect on '
      'the next Continue tap — the flow re-reads the seam at call time, '
      'so a stale closure captured in initState does not get reused',
      (tester) async {
    final prefs = await _freshPrefs();

    var current = () async => false;
    Widget tree() => MaterialApp(
          home: PermissionScreen(
            preferences: prefs,
            requestPermissions: () => current(),
            onGranted: (_) {},
          ),
        );

    await tester.pumpWidget(tree());

    // First tap with the deny-callback → lands in the denied state.
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);

    // Swap the callback to one that grants, rebuild the parent, then
    // recover to rationale and tap Continue again. If the flow snapshotted
    // the old closure at construction the second tap would still deny.
    current = () async => true;
    await tester.pumpWidget(tree());
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.text('Continue'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    // Granted path leaves the rationale view (no Try again surfaced).
    expect(find.text('Try again'), findsNothing);
  });
}
