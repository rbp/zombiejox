import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/home_screen.dart';
import 'screens/permission_screen.dart';
import 'state/preferences.dart';
import 'theme/app_theme.dart';

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
/// decide between the rationale screen (not granted) and going straight
/// to the home screen (granted). Re-checked on every cold start so OS-
/// level revocations re-trigger the rationale.
///
/// Defaults to `false` on plugin-channel failure so a flaky platform call
/// can't crash startup — the user lands on the rationale screen, which is
/// the safer fallback (it has the Open-Settings escape hatch).
Future<bool> _bluetoothPermissionsGranted() async {
  try {
    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    return scan.isGranted && connect.isGranted;
  } catch (_) {
    return false;
  }
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
        ? HomeScreen(preferences: preferences)
        : PermissionScreen(preferences: preferences);

    return MaterialApp(
      title: 'ZombieJox',
      theme: AppTheme.darkTheme(),
      home: home,
    );
  }
}
