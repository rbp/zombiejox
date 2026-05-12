import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zombiejox/screens/about_screen.dart';
import 'package:zombiejox/screens/settings_screen.dart';
import 'package:zombiejox/state/preferences.dart';
import 'package:zombiejox/state/weights.dart';

Future<Preferences> _prefs({WeightUnit initial = WeightUnit.lbs}) async {
  SharedPreferences.setMockInitialValues({'units': initial.name});
  return Preferences.load();
}

void main() {
  testWidgets('renders current unit + reflects the active selection',
      (tester) async {
    final prefs = await _prefs(initial: WeightUnit.lbs);
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(preferences: prefs),
    ));

    expect(find.text('Units'), findsOneWidget);
    expect(find.text('lbs'), findsOneWidget);
    expect(find.text('kg'), findsOneWidget);
    expect(find.text('About ZombieJox'), findsOneWidget);
  });

  testWidgets('tapping kg flips the preference and re-labels the segment',
      (tester) async {
    final prefs = await _prefs(initial: WeightUnit.lbs);
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(preferences: prefs),
    ));

    expect(prefs.unit.value, WeightUnit.lbs);

    await tester.tap(find.text('kg'));
    await tester.pumpAndSettle();

    expect(prefs.unit.value, WeightUnit.kg);
  });

  testWidgets('tapping About navigates to the About screen', (tester) async {
    final prefs = await _prefs();
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(preferences: prefs),
    ));

    await tester.tap(find.text('About ZombieJox'));
    await tester.pumpAndSettle();

    expect(find.byType(AboutScreen), findsOneWidget);
  });
}
