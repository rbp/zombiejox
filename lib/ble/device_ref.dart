/// Plugin-agnostic handle to a single BLE peripheral.
///
/// The domain layer (`devices/`, `state/`, `screens/`, `widgets/`) only ever
/// holds these — never `flutter_blue_plus`'s `BluetoothDevice`. The adapter
/// in `lib/ble/ble_service.dart` is what turns a [DeviceRef] back into the
/// plugin's concrete device when it's actually time to talk to the radio.
///
/// Identity is the [id] (the remote-id string the platform exposes — MAC on
/// Android, UUID on iOS). Two [DeviceRef]s with the same [id] and different
/// names are still the same peripheral; equality and hashCode reflect that
/// so a [DeviceRef] is safe to use as a [Set] / [Map] key.
class DeviceRef {
  /// Platform remote id. Stable across runs on Android (MAC); on iOS it's
  /// the system-assigned UUID, which is stable for a given (peripheral,
  /// app) pair.
  final String id;

  /// Advertised name at scan time, or empty if the peripheral didn't
  /// advertise one. Use [displayName] for user-facing rendering.
  final String name;

  const DeviceRef({required this.id, this.name = ''});

  /// Advertised name when non-empty, [id] otherwise. Centralised so every
  /// device-row widget agrees on the same fallback.
  String get displayName => name.isEmpty ? id : name;

  @override
  bool operator ==(Object other) => other is DeviceRef && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'DeviceRef($id)';
}
