import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Extension that gives [BluetoothDevice] a `displayName`: its advertised
/// name when available, the remote-id string otherwise. Centralised here
/// so every device-row widget agrees on the same fallback.
extension BluetoothDeviceDisplay on BluetoothDevice {
  String get displayName {
    final adv = advName;
    return adv.isEmpty ? remoteId.str : adv;
  }
}
