/// Plugin-agnostic connection state for a single BLE peripheral.
///
/// Mirrors the subset of `flutter_blue_plus`'s `BluetoothConnectionState` we
/// actually consume — `connecting`/`connected`/`disconnected`. Disconnecting
/// is collapsed into `disconnected` because no caller distinguishes the two.
enum BleConnectionState { connecting, connected, disconnected }
