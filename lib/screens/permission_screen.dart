import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../state/preferences.dart';
import 'scan_screen.dart';

/// Pre-permission rationale shown before the OS Bluetooth
/// prompt fires. Critical on iOS where a denied prompt cannot be re-prompted
/// — the user has to be sent to Settings.app to recover. By framing the
/// "why" first, we improve the chance the user grants on the first try.
///
/// This is also the single source of truth for re-grant flows: if the user
/// later revokes permission via Settings.app, [ScanScreen] detects the loss
/// and `pushReplacement`'s back here rather than handling it inline. Keeping
/// the rationale + denied + "Open Settings" UI in one place avoids drift.
class PermissionScreen extends StatefulWidget {
  final Preferences preferences;

  /// Override the BLE permission request — used by widget tests to avoid the
  /// `permission_handler` platform channel. In production this is null and
  /// the screen calls [_defaultRequestPermissions].
  final Future<bool> Function()? requestPermissions;

  /// Override the "permissions granted, move on" navigation — used by widget
  /// tests so we don't actually push a `ScanScreen` (whose own `initState`
  /// would hit the platform channel). In production this is null and the
  /// screen calls [_defaultOnGranted] which `pushReplacement`'s to scan.
  final void Function(BuildContext)? onGranted;

  const PermissionScreen({
    super.key,
    required this.preferences,
    this.requestPermissions,
    this.onGranted,
  });

  // Android 12+ uses BLUETOOTH_SCAN with `neverForLocation`, so location is
  // not requested. On iOS we'd crash without `NSLocationWhenInUseUsageDescription`
  // in Info.plist, so location is never requested on either platform.
  // Android ≤11 (where scanning requires ACCESS_FINE_LOCATION) is not
  // supported by this build — see IMPLEMENTATION_PLAN.md.
  static Future<bool> _defaultRequestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    return statuses[Permission.bluetoothScan]?.isGranted == true &&
        statuses[Permission.bluetoothConnect]?.isGranted == true;
  }

  void _defaultOnGranted(BuildContext context) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ScanScreen(preferences: preferences),
      ),
    );
  }

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _denied = false;
  bool _requesting = false;

  Future<void> _onContinue() async {
    if (_requesting) return;
    setState(() => _requesting = true);

    final request = widget.requestPermissions ??
        PermissionScreen._defaultRequestPermissions;

    // A platform-channel failure (e.g. MissingPluginException, transient
    // plugin error) shouldn't leave the button stuck on "Requesting…" or
    // bubble up as an uncaught async exception. Treat it as a soft denial:
    // the user still ends up on the denied screen with the Open Settings
    // escape hatch.
    bool granted;
    try {
      granted = await request();
    } catch (_) {
      granted = false;
    }

    if (!mounted) return;

    if (granted) {
      final onGranted = widget.onGranted ?? widget._defaultOnGranted;
      onGranted(context);
    } else {
      setState(() {
        _requesting = false;
        _denied = true;
      });
    }
  }

  Future<void> _openSettings() async {
    await openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.bluetooth,
                size: 72,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                'ZombieJox needs Bluetooth',
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                _denied
                    ? 'Permission was denied. ZombieJox can\'t talk to your '
                        'JaxJox dumbbells without Bluetooth access. You can '
                        'grant it in your phone\'s settings.'
                    : 'ZombieJox uses Bluetooth to talk to your JaxJox '
                        'dumbbells. No data leaves your phone — no cloud, no '
                        'account, no telemetry.',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (_denied) ...[
                FilledButton(
                  onPressed: _openSettings,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Open Settings'),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => setState(() => _denied = false),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Try again'),
                  ),
                ),
              ] else
                FilledButton(
                  onPressed: _requesting ? null : _onContinue,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_requesting ? 'Requesting…' : 'Continue'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
