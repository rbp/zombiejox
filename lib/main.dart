import 'package:flutter/material.dart';

import 'screens/scan_screen.dart';
import 'state/preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await Preferences.load();
  runApp(ZombieJoxApp(preferences: prefs));
}

class ZombieJoxApp extends StatelessWidget {
  final Preferences preferences;

  const ZombieJoxApp({super.key, required this.preferences});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZombieJox',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: ScanScreen(preferences: preferences),
    );
  }
}
