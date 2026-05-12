/// Plugin-agnostic connection state for a single BLE peripheral.
///
/// The two states `flutter_blue_plus` actually emits on the platforms we
/// support are `connected` and `disconnected`. `connecting` is the value
/// `BleConnection.connectionState` reports for any *intermediate* state
/// the plugin might surface in the future (e.g. a re-introduced
/// `disconnecting`) — "neither live nor cleanly gone" rounds to
/// "not-yet-live" for the UI, which only ever asks "is this connected?".
enum BleConnectionState { connecting, connected, disconnected }
