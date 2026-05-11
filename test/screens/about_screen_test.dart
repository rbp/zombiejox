import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/screens/about_screen.dart';

void main() {
  // The about screen is a scrolling list — give the test viewport enough
  // room to render every section without needing to scroll. Keeps each
  // `find.text` call simple.
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  Future<void> pumpAbout(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
  }

  testWidgets('renders the project name, credits, license, and disclaimer',
      (tester) async {
    await pumpAbout(tester);

    // The H1 "ZombieJox" plus the AppBar title both contain the text — so
    // findsWidgets (≥ 1) is the safe assertion here.
    expect(find.text('ZombieJox'), findsWidgets);
    expect(find.text('Credits'), findsOneWidget);
    expect(find.textContaining('Eamon Tuhami'), findsOneWidget);
    expect(find.textContaining('JaxJox engineering team'), findsOneWidget);

    expect(find.text('License'), findsOneWidget);
    expect(find.textContaining('GPLv3'), findsOneWidget);

    expect(find.text('Disclaimer'), findsOneWidget);
    expect(find.textContaining('not affiliated with JaxJox'), findsOneWidget);
  });

  testWidgets('mentions docs/ble_protocol.md as the protocol reference',
      (tester) async {
    await pumpAbout(tester);
    expect(find.textContaining('docs/ble_protocol.md'), findsOneWidget);
  });
}
