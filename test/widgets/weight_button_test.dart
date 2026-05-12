// ignore_for_file: deprecated_member_use

import 'dart:ui' show SemanticsFlag;

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

  testWidgets(
      'selected → Semantics reports selected + a label that calls it out; '
      'unselected → Semantics reports not-selected + the bare label',
      (tester) async {
    // The previous assertion ("FilledButton vs FilledButton.tonal") didn't
    // actually distinguish — `FilledButton.tonal` is a factory that
    // returns a `FilledButton`, so both branches matched `findsOneWidget`.
    // The user-meaningful distinction is whether the button is announced
    // as selected by VoiceOver / TalkBack, which is what `Semantics` flags
    // and what we actually care about.
    await _pump(
      tester,
      const WeightButton(
        index: 0,
        unit: WeightUnit.lbs,
        selected: true,
        onPressed: null,
      ),
    );
    var node =
        tester.getSemantics(find.bySemanticsLabel('8 lbs, currently set'));
    expect(node.hasFlag(SemanticsFlag.isSelected), isTrue);

    await _pump(
      tester,
      const WeightButton(
        index: 0,
        unit: WeightUnit.lbs,
        selected: false,
        onPressed: null,
      ),
    );
    node = tester.getSemantics(find.bySemanticsLabel('8 lbs'));
    expect(node.hasFlag(SemanticsFlag.isSelected), isFalse);
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
