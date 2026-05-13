import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'device_ref.dart';

/// One advertisement match from a running scan.
///
/// Plugin-agnostic by construction — the [device] is a [DeviceRef], not a
/// `BluetoothDevice`. Consumers above `lib/ble/` see only this shape.
class ScanHit {
  final DeviceRef device;
  final int rssi;
  const ScanHit({required this.device, required this.rssi});
}

/// Coarse adapter state — what HomeScreen renders against. We collapse
/// the plugin's broader enum (`turningOn`/`turningOff` etc.) into "is
/// the radio usable right now or not, and if not, why" because that's
/// the only distinction the UI cares about.
enum BleAdapterState {
  /// Radio is on and the app may scan / connect.
  on,

  /// Radio is off (user toggled BT off, or it never came up). The UI
  /// surfaces a "Bluetooth is off" banner with an Open Settings button.
  off,

  /// The OS reports the adapter is unauthorized — typically a
  /// permission issue, not a hardware one. Distinct from [unsupported]
  /// because the recovery path is "grant Bluetooth permission" via
  /// app settings, not "buy different hardware". `HomeScreen`'s
  /// permission-on-resume re-check will usually catch this same
  /// scenario and route to `PermissionScreen` — but we keep a
  /// dedicated banner state for the window where the adapter has
  /// reported `unauthorized` and the permission check hasn't run yet.
  unauthorized,

  /// Hardware doesn't support BLE (or the plugin reports it
  /// unavailable). Terminal — there's no recovery path the user can
  /// take. We still render a banner so they understand why nothing
  /// works.
  unsupported,

  /// The OS hasn't told us yet. Treated like `off` for UI gating but
  /// surfaces a less alarming wording — gives the platform a moment to
  /// report state before we accuse it of being broken.
  unknown,
}

/// Plugin-agnostic BLE scan surface.
///
/// Implementations:
///   - [FlutterBluePlusScanner] — production adapter backed by
///     `FlutterBluePlus` statics.
///   - Tests can pass a fake to `HomeScreen` when they want to assert on
///     the scan UI without invoking the platform channel.
abstract class BleScanner {
  /// Synchronous current scanning state.
  bool get isScanningNow;

  /// Reactive scanning state — wired into the scan-screen toolbar icon.
  Stream<bool> get isScanning;

  /// Live list of scan results, deduped by device by the underlying plugin.
  Stream<List<ScanHit>> get results;

  /// Reactive BLE adapter state. HomeScreen renders a "Bluetooth is off"
  /// banner when this isn't [BleAdapterState.on]. The stream emits the
  /// current value to new subscribers (production: backed by
  /// FlutterBluePlus.adapterState which behaves this way).
  Stream<BleAdapterState> get adapterState;

  /// Best-effort start. Adapters typically swallow platform errors so a
  /// flaky BT adapter doesn't crash the UI; the user can retry from the
  /// refresh icon.
  Future<void> startScan({
    List<String> withKeywords = const [],
    Duration? timeout,
  });

  /// Best-effort stop. Safe to call when no scan is running.
  Future<void> stopScan();

  /// Ask the platform to enable Bluetooth. On Android, this pops the
  /// system "Allow Bluetooth?" dialog right in the app (via
  /// `BluetoothAdapter.ACTION_REQUEST_ENABLE`) and resolves to `true`
  /// once the user accepts, `false` on deny. **Android only**: iOS
  /// doesn't expose a programmatic toggle (the user has to flip BT in
  /// Settings or Control Center); the iOS implementation returns
  /// `false` without prompting. UIs should hide the "Enable Bluetooth"
  /// CTA on iOS and fall back to a text instruction.
  Future<bool> turnOnBluetooth();
}

/// Production [BleScanner] backed by `flutter_blue_plus`'s static API.
class FlutterBluePlusScanner implements BleScanner {
  const FlutterBluePlusScanner();

  @override
  bool get isScanningNow => FlutterBluePlus.isScanningNow;

  @override
  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  @override
  Stream<List<ScanHit>> get results => FlutterBluePlus.scanResults.map(
        (list) => [
          for (final r in list)
            ScanHit(
              device: DeviceRef(
                id: r.device.remoteId.str,
                name: r.advertisementData.advName,
              ),
              rssi: r.rssi,
            ),
        ],
      );

  @override
  Stream<BleAdapterState> get adapterState =>
      FlutterBluePlus.adapterState.map(_mapAdapterState);

  @override
  Future<void> startScan({
    List<String> withKeywords = const [],
    Duration? timeout,
  }) {
    return FlutterBluePlus.startScan(
      withKeywords: withKeywords,
      timeout: timeout ?? const Duration(seconds: 30),
    );
  }

  @override
  Future<void> stopScan() => FlutterBluePlus.stopScan();

  @override
  Future<bool> turnOnBluetooth() async {
    // `FlutterBluePlus.turnOn()` returns `Future<void>` — it throws on
    // user-rejection ("userRejected") or platform unsupported (iOS).
    // Map both cases to `false` for the UI; success → true. Adapter
    // state will flip to `on` independently via the adapterState stream
    // so the banner hides itself as soon as the radio comes up.
    try {
      await FlutterBluePlus.turnOn();
      return true;
    } catch (_) {
      return false;
    }
  }

  static BleAdapterState _mapAdapterState(BluetoothAdapterState s) {
    switch (s) {
      case BluetoothAdapterState.on:
        return BleAdapterState.on;
      case BluetoothAdapterState.off:
      case BluetoothAdapterState.turningOff:
        return BleAdapterState.off;
      case BluetoothAdapterState.unauthorized:
        return BleAdapterState.unauthorized;
      case BluetoothAdapterState.unavailable:
        return BleAdapterState.unsupported;
      // `turningOn` and `unknown` round to `unknown` — the platform is
      // mid-flip or hasn't reported, so we show the muted "checking"
      // wording rather than the "radio is off" alarm.
      default:
        return BleAdapterState.unknown;
    }
  }
}
