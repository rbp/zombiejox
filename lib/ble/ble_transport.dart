import 'ble_connection_state.dart';
import 'device_ref.dart';

/// Per-device BLE transport — the seam between the protocol layer and any
/// concrete BLE plugin. `BleConnection` (in `ble_service.dart`) is the
/// only implementation, and `Dumbbell` picks it directly in its
/// constructor; what the interface buys us is that everything `Dumbbell`
/// exposes upward — and therefore everything `state/`, `screens/`, and
/// `widgets/` consume — is typed against [BleTransport] + [DeviceRef], so
/// the `flutter_blue_plus` types stay contained inside `lib/ble/`. Tests
/// fake [Dumbbell] by subclassing it directly and overriding its public
/// methods — that path bypasses [BleTransport] entirely.
///
/// Lifecycle: [connect] → use → [disconnect]. [disconnect] is idempotent
/// and best-effort: callers can invoke it after a successful [connect],
/// after a failed one, or twice in a row without special casing.
abstract class BleTransport {
  /// Plugin-agnostic handle to the peripheral this transport drives.
  DeviceRef get device;

  /// Bytes received on the JaxJox RX characteristic. Broadcast — multiple
  /// listeners are fine.
  Stream<List<int>> get rxStream;

  /// Coarse connection state from the platform.
  Stream<BleConnectionState> get connectionState;

  /// Open the connection, discover the JaxJox service, hook RX, and resolve
  /// the standard Battery Service if the firmware exposes it. If any step
  /// throws, partially-initialised resources are released before rethrow —
  /// the caller's `catch` doesn't need to know what step failed.
  Future<void> connect();

  /// Write a framed payload to the TX characteristic.
  ///
  /// Throws [StateError] if called before [connect] has completed (or after
  /// [disconnect]).
  Future<void> writeTx(List<int> bytes);

  /// Read the standard Battery Service level if the firmware exposes one;
  /// returns null otherwise (older firmwares lack the service).
  Future<int?> readBatteryLevel();

  /// Idempotent + best-effort. Each step is independently guarded so a
  /// failure in one (e.g. the BLE adapter is in a bad state) still releases
  /// the rest. Calling [disconnect] twice, or before a successful [connect],
  /// is fine.
  Future<void> disconnect();
}
