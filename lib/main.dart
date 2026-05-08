import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/permission_screen.dart';
import 'screens/scan_screen.dart';
import 'state/preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await Preferences.load();
  final permissionsGranted = await _bluetoothPermissionsGranted();
  runApp(ZombieJoxApp(
    preferences: prefs,
    permissionsGranted: permissionsGranted,
  ));
}

/// Quick non-prompting check of the Bluetooth permission state. Used to
/// decide between the rationale screen (not granted) and going straight to
/// scan (granted). Re-checked on every cold start so OS-level revocations
/// re-trigger the rationale.
Future<bool> _bluetoothPermissionsGranted() async {
  final scan = await Permission.bluetoothScan.status;
  final connect = await Permission.bluetoothConnect.status;
  return scan.isGranted && connect.isGranted;
}

class ZombieJoxApp extends StatelessWidget {
  final Preferences preferences;
  final bool permissionsGranted;

  const ZombieJoxApp({
    super.key,
    required this.preferences,
    required this.permissionsGranted,
  });

  @override
  Widget build(BuildContext context) {
    final home = permissionsGranted
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
