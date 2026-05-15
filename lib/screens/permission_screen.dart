import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../state/bluetooth_permissions.dart';
import '../state/permission_request_flow.dart';
import '../state/preferences.dart';
import 'home_screen.dart';

/// Pre-permission rationale shown before the OS Bluetooth
/// prompt fires. Critical on iOS where a denied prompt cannot be re-prompted
/// — the user has to be sent to Settings.app to recover. By framing the
/// "why" first, we improve the chance the user grants on the first try.
///
/// This is also the single source of truth for re-grant flows: if the user
/// later revokes permission via Settings.app, [HomeScreen] detects the loss
/// and `pushReplacement`'s back here rather than handling it inline. Keeping
/// the rationale + denied + "Open Settings" UI in one place avoids drift.
///
/// The transitions (rationale → requesting → denied / granted, plus the
/// soft-denial-on-platform-exception rule) live in
/// [PermissionRequestFlow] so they're testable as plain Dart.
class PermissionScreen extends StatefulWidget {
  final Preferences preferences;

  /// Override the BLE permission request — used by widget tests to avoid the
  /// `permission_handler` platform channel. In production this is null and
  /// the screen calls [_defaultRequestPermissions].
  final Future<bool> Function()? requestPermissions;

  /// Override the "permissions granted, move on" navigation — used by
  /// widget tests so we don't actually push a `HomeScreen` (whose own
  /// `initState` would hit the platform channel). In production this is
  /// null and the screen calls [_defaultOnGranted] which
  /// `pushReplacement`'s to home.
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
  // supported by this build. The iOS-vs-Android
  // permission split lives in `state/bluetooth_permissions.dart`.
  static Future<bool> _defaultRequestPermissions() => requestBluetoothPermissions();

  void _defaultOnGranted(BuildContext context) {
    unawaited(
      Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
          builder: (_) => HomeScreen(preferences: preferences),
        ),
      ),
    );
  }

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  // Re-read `widget.requestPermissions` on every call so that if the
  // parent rebuilds with a different seam (e.g. a test swapping it
  // mid-screen), the next Continue tap picks up the new callback rather
  // than the one that was current when the flow was constructed.
  late final PermissionRequestFlow _flow = PermissionRequestFlow(
    request: () => (widget.requestPermissions ?? PermissionScreen._defaultRequestPermissions)(),
  );

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  Future<void> _onContinue() async {
    final granted = await _flow.requestPermissions();
    if (!mounted) return;
    if (granted) {
      final onGranted = widget.onGranted ?? widget._defaultOnGranted;
      onGranted(context);
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
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: ValueListenableBuilder<PermissionFlowState>(
                valueListenable: _flow.state,
                builder: (context, state, _) {
                  final denied = state == PermissionFlowState.denied;
                  final requesting = state == PermissionFlowState.requesting;
                  // iOS sends the user to a per-app Settings page with a
                  // single Bluetooth toggle; Android buries it under the
                  // app's permissions list. A generic "in your settings"
                  // line leaves users hunting, so spell the path out.
                  // The Open Settings button deep-links to the right
                  // place via UIApplicationOpenSettingsURLString /
                  // Android's app-detail intent; this breadcrumb is just
                  // for users who navigate manually. The iOS path is
                  // also valid on iOS 17+ even though that release added
                  // a `Settings → Apps` consolidation — per-app entries
                  // still appear at the root.
                  final isAndroid = defaultTargetPlatform == TargetPlatform.android;
                  final deniedPath = isAndroid
                      ? 'Settings → Apps → ZombieJox → Permissions → '
                          'Nearby devices'
                      : 'Settings → ZombieJox → Bluetooth';
                  return Column(
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
                        denied
                            ? 'Permission was denied. ZombieJox can\'t talk to your '
                                'JaxJox dumbbells without Bluetooth access. Tap '
                                'Open Settings, then grant it under $deniedPath.'
                            : 'ZombieJox uses Bluetooth to talk to your JaxJox '
                                'dumbbells. No data leaves your phone — no cloud, no '
                                'account, no telemetry.',
                        style: theme.textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      if (denied) ...[
                        FilledButton(
                          onPressed: _openSettings,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('Open Settings'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _flow.tryAgain,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('Try again'),
                          ),
                        ),
                      ] else
                        FilledButton(
                          onPressed: requesting ? null : _onContinue,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(requesting ? 'Requesting…' : 'Continue'),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
