import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:permission_handler/permission_handler.dart';

/// The `permission_handler` keys for the BT permissions we need on the
/// current platform.
///
/// **iOS:** only `Permission.bluetooth` is a real permission. The
/// Android-12-style `Permission.bluetoothScan` / `bluetoothConnect` keys
/// route through `UnknownPermissionStrategy` in `permission_handler_apple`
/// and always report `permanentlyDenied` — which would trap the user on
/// the denied screen even after they tap Allow on the OS prompt. Asking
/// for `Permission.bluetooth` delegates to `CBCentralManager`, which
/// fires the real prompt and reports the real result.
///
/// **Android 12+:** the runtime-permission split is canonical;
/// `Permission.bluetooth` is the legacy pre-12 manifest permission and
/// doesn't trigger the right prompt on modern Android.
@visibleForTesting
List<Permission> platformBlePermissions() {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return const [Permission.bluetooth];
  }
  return const [Permission.bluetoothScan, Permission.bluetoothConnect];
}

/// Triggers the OS prompt(s) for the BT permissions we need and reports
/// whether every required permission ended up granted.
Future<bool> requestBluetoothPermissions() async {
  final perms = platformBlePermissions();
  final statuses = await perms.request();
  return perms.every((p) => statuses[p]?.isGranted == true);
}

/// Reads the current BT permission status without triggering a prompt.
/// Returns true iff every required BT permission is currently granted.
/// Used at startup and on app-resume to decide between the rationale
/// screen and Home.
Future<bool> bluetoothPermissionsGranted() async {
  for (final p in platformBlePermissions()) {
    final status = await p.status;
    if (!status.isGranted) return false;
  }
  return true;
}
