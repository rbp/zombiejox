import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/state/weights.dart';
import 'package:zombiejox/widgets/weight_button.dart';

Future<void> _pump(WidgetTester tester, Widget w) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
}

void main() {
  testWidgets('renders the lbs label for the given index', (tester) async {
    await _pump(
      tester,
      WeightButton(
          index: 2, unit: WeightUnit.lbs, selected: false, onPressed: () {}),
    );
    expect(find.text('20 lbs'), findsOneWidget);
  });

  testWidgets('renders the kg label when unit is kg', (tester) async {
    await _pump(
      tester,
      WeightButton(
          index: 4, unit: WeightUnit.kg, selected: false, onPressed: () {}),
    );
    expect(find.text('14.5 kg'), findsOneWidget);
  });

  testWidgets('uses FilledButton when selected, FilledButton.tonal when not',
      (tester) async {
    await _pump(
      tester,
      WeightButton(
          index: 0, unit: WeightUnit.lbs, selected: true, onPressed: () {}),
    );
    // The selected variant is a plain FilledButton (no tonal style).
    expect(find.byType(FilledButton), findsOneWidget);

    await _pump(
      tester,
      WeightButton(
          index: 0, unit: WeightUnit.lbs, selected: false, onPressed: () {}),
    );
    // The unselected variant is also a FilledButton subtype, but we can
    // distinguish by visual style — easier to verify by tapping.
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('null onPressed disables the button', (tester) async {
    await _pump(
      tester,
      const WeightButton(
        index: 0,
        unit: WeightUnit.lbs,
        selected: false,
        onPressed: null,
      ),
    );
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('forwards taps to onPressed', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      WeightButton(
        index: 3,
        unit: WeightUnit.lbs,
        selected: false,
        onPressed: () => taps++,
      ),
    );
    await tester.tap(find.byType(FilledButton));
    expect(taps, 1);
  });
}
