/// Plugin-agnostic connection state for a single BLE peripheral.
///
/// `flutter_blue_plus` only ever emits `connected` / `disconnected` on
/// the platforms we support — the plugin's deprecated `connecting`
/// value never reaches our stream. The two-value enum gives consumers
/// (today: `DumbbellCard`) a typed signal for "is this device live or
/// not", distinct from the `null` that a `StreamBuilder` reports
/// before any event has arrived.
enum BleConnectionState { connected, disconnected }
