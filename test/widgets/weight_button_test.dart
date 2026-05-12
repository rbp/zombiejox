// ignore_for_file: deprecated_member_use

import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/state/weights.dart';
import 'package:zombiejox/widgets/weight_button.dart';

Future<void> _pump(WidgetTester tester, Widget w) async {
  // Constrain the tile so InkWell-inside-Material has a finite size to
  // render into. Mirrors the grid cell shape the production layout
  // gives us.
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: 120, height: 80, child: w),
      ),
    ),
  ));
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
    // Selection isn't a button-variant swap any more (PR 1 of the design
    // redo replaced FilledButton / FilledButton.tonal with a single
    // rounded tile whose fill comes from the active scheme). The
    // user-meaningful distinction is whether the tile is announced as
    // selected by VoiceOver / TalkBack — that's what `Semantics` flags
    // and what we still assert on.
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
    // The tile's InkWell has a null onTap when the parent's onPressed is
    // null — that's what blocks taps even though the visual tile remains
    // in place.
    final ink = tester.widget<InkWell>(find.byType(InkWell));
    expect(ink.onTap, isNull);
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
    await tester.tap(find.byType(InkWell));
    expect(taps, 1);
  });

  testWidgets(
      'label fits at TextScaler 1.6× without clipping — large-font safety',
      (tester) async {
    // FittedBox(scaleDown) inside the tile should shrink the label to
    // fit the cell at large text scales. We assert the label is still
    // present and the rendered text isn't laid out past its parent.
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 60,
              child: WeightButton(
                index: 4, // "32 lbs" — one of the wider labels
                unit: WeightUnit.lbs,
                selected: false,
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    ));
    expect(find.text('32 lbs'), findsOneWidget);
    final textBox = tester.getRect(find.text('32 lbs'));
    // Measure the Material descendant rather than the WeightButton
    // (StatelessWidget) itself — `getRect` needs a RenderObject-backed
    // target. The Material wraps the entire tile and is what defines its
    // visual bounds.
    final tileBox = tester.getRect(
      find.descendant(
        of: find.byType(WeightButton),
        matching: find.byType(Material),
      ),
    );
    expect(textBox.width, lessThanOrEqualTo(tileBox.width));
    expect(textBox.height, lessThanOrEqualTo(tileBox.height));
  });
}
