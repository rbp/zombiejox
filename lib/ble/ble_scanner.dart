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

  /// Best-effort start. Adapters typically swallow platform errors so a
  /// flaky BT adapter doesn't crash the UI; the user can retry from the
  /// refresh icon.
  Future<void> startScan({
    List<String> withKeywords = const [],
    Duration? timeout,
  });

  /// Best-effort stop. Safe to call when no scan is running.
  Future<void> stopScan();
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
}
