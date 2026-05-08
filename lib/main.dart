import 'package:flutter/material.dart';

import 'screens/permission_screen.dart';
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
    // Show the rationale + permission flow once per install. Subsequent
    // launches go straight to scan — if permission was revoked between
    // launches, the scan screen has its own re-grant prompt.
    final home = preferences.hasShownBluetoothRationale
        ? ScanScreen(preferences: preferences)
        : PermissionScreen(preferences: preferences);

    return MaterialApp(
      title: 'ZombieJox',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: home,
    );
  }
}
