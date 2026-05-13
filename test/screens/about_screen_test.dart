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

  Future<List<Uri>> pumpAbout(
    WidgetTester tester, {
    bool launchResult = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final launched = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      home: AboutScreen(
        launchUri: (u) async {
          launched.add(u);
          return launchResult;
        },
      ),
    ));
    return launched;
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

  testWidgets('renders the logo at the top + the GitHub + author links',
      (tester) async {
    await pumpAbout(tester);

    expect(find.byType(Image), findsOneWidget,
        reason: 'logo above the app name');
    expect(find.textContaining('github.com/rbp/zombiejox'), findsOneWidget);
    expect(find.textContaining('Rodrigo Pimentel'), findsOneWidget);
    expect(find.textContaining('rbp@isnomore.net'), findsOneWidget);
    expect(find.textContaining('started this project'), findsOneWidget);
  });

  testWidgets('tapping the GitHub row launches the repo URL', (tester) async {
    final launched = await pumpAbout(tester);

    await tester.tap(find.textContaining('github.com/rbp/zombiejox'));
    await tester.pump();

    expect(launched, hasLength(1));
    expect(launched.single.toString(), 'https://github.com/rbp/zombiejox');
  });

  testWidgets('tapping the author row launches a mailto: URL',
      (tester) async {
    final launched = await pumpAbout(tester);

    await tester.tap(find.textContaining('Rodrigo Pimentel'));
    await tester.pump();

    expect(launched, hasLength(1));
    expect(launched.single.scheme, 'mailto');
    expect(launched.single.path, 'rbp@isnomore.net');
  });

  testWidgets('a failing launch surfaces a SnackBar (not an uncaught error)',
      (tester) async {
    await pumpAbout(tester, launchResult: false);
    await tester.tap(find.textContaining('github.com/rbp/zombiejox'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Could not open'), findsOneWidget);
  });
}
