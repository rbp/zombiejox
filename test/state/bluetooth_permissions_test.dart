import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zombiejox/state/bluetooth_permissions.dart';

void main() {
  group('platformBlePermissions', () {
    test(
        'iOS asks for Permission.bluetooth (the real CBCentralManager-backed '
        'permission) and NOT Permission.bluetoothScan / bluetoothConnect — '
        'those route to UnknownPermissionStrategy in permission_handler_apple '
        'and would always report permanentlyDenied, trapping the user on the '
        'denied screen', () {
      // Reset inside the test body (not via addTearDown): the framework's
      // invariant check fires before tearDowns run.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(platformBlePermissions(), const [Permission.bluetooth]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test(
        'Android asks for the runtime-permission split '
        '(bluetoothScan + bluetoothConnect) — the legacy Permission.bluetooth '
        'is the pre-12 manifest permission and doesn\'t trigger the right '
        'prompt on Android 12+', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        expect(
          platformBlePermissions(),
          const [Permission.bluetoothScan, Permission.bluetoothConnect],
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
