import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/ble_scanner.dart';
import '../ble/device_ref.dart';
import '../ble/uuids.dart';
import '../state/preferences.dart';
import 'control_screen.dart';
import 'permission_screen.dart';
import 'settings_screen.dart';

class ScanScreen extends StatefulWidget {
  final Preferences preferences;

  /// Override the Bluetooth-permission status check — used by widget tests
  /// to avoid the `permission_handler` platform channel. In production
  /// this is null and the screen reads `Permission.bluetoothScan.status`
  /// + `bluetoothConnect.status` directly.
  final Future<bool> Function()? checkPermissionsGranted;

  /// Override the route that's pushed for the connected devices — used by
  /// widget tests so we don't actually pump a real ControlScreen (whose
  /// `initState` would hit BLE platform channels). In production this is
  /// null and the screen pushes a [ControlScreen].
  final Widget Function(BuildContext context, List<DeviceRef> devices,
      VoidCallback onAnyConnected)? controlScreenBuilder;

  /// Override the BLE scan source — tests pass a fake to avoid touching
  /// the `flutter_blue_plus` static API. Production uses
  /// [FlutterBluePlusScanner].
  final BleScanner? scanner;

  const ScanScreen({
    super.key,
    required this.preferences,
    this.checkPermissionsGranted,
    this.controlScreenBuilder,
    this.scanner,
  });

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  late final BleScanner _scanner =
      widget.scanner ?? const FlutterBluePlusScanner();
  bool _checking = true;
  // Sticky: once we've decided whether to auto-connect on cold start, we
  // don't redo it when the user pops back from ControlScreen (e.g. via
  // Disconnect-all). They probably want to pick different dumbbells.
  bool _autoConnectAttempted = false;
  final Set<DeviceRef> _selected = <DeviceRef>{};

  @override
  void initState() {
    super.initState();
    _ensurePermissions();
  }

  /// Permissions should already be granted by the time the user lands here:
  /// `main.dart` routes a cold start through [PermissionScreen] when they're
  /// not, and [PermissionScreen]'s own success path `pushReplacement`'s here.
  /// This is a defensive backstop for the OS-level-revocation case (the user
  /// toggles Bluetooth off in Settings.app while the app is alive). On miss,
  /// we hand control back to [PermissionScreen] rather than re-prompting
  /// inline — iOS won't re-prompt once denied, so the rationale + Settings
  /// flow lives in one place.
  static Future<bool> _defaultCheckPermissionsGranted() async {
    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    return scan.isGranted && connect.isGranted;
  }

  Future<void> _ensurePermissions() async {
    final granted = await (widget.checkPermissionsGranted ??
        _defaultCheckPermissionsGranted)();
    if (!mounted) return;
    if (!granted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PermissionScreen(preferences: widget.preferences),
        ),
      );
      return;
    }

    // Warm-start fast path: if we remember dumbbells from a previous run,
    // navigate straight to ControlScreen and let it kick off connects in
    // parallel. The scan UI stays "checking" underneath so the user
    // doesn't see a flash of the empty scan list during the transition.
    if (!_autoConnectAttempted) {
      _autoConnectAttempted = true;
      final ids = widget.preferences.rememberedDeviceIds;
      if (ids.isNotEmpty) {
        await _navigateToControl([
          for (final id in ids) DeviceRef(id: id),
        ]);
        return;
      }
    }

    setState(() => _checking = false);
    _startScan();
  }

  Future<void> _startScan() async {
    // The BLE adapter can fail to start a scan for reasons we can't
    // recover from inline (Bluetooth got turned off, adapter is in an
    // odd state, platform channel error). Swallow + log; the user has a
    // refresh icon they can hit once the underlying issue is fixed.
    try {
      if (_scanner.isScanningNow) {
        await _scanner.stopScan();
      }
      // The native filter (`withKeywords`) is an efficiency hint — it
      // cuts BLE advertisement churn. The *authoritative* filter is
      // `_isJaxJox` applied to the stream results below, which also
      // rejects DFU-mode names ending in `U`.
      await _scanner.startScan(
        withKeywords: kJaxJoxNamePrefixes,
        timeout: const Duration(seconds: 30),
      );
    } catch (e, st) {
      debugPrint('startScan failed: $e\n$st');
    }
  }

  void _toggleSelected(DeviceRef device) {
    setState(() {
      if (_selected.contains(device)) {
        _selected.remove(device);
      } else {
        _selected.add(device);
      }
    });
  }

  Future<void> _onConnect() async {
    if (_selected.isEmpty) return;
    final devices = _selected.toList();
    // Same as _startScan — don't let an adapter-state error stall us.
    try {
      await _scanner.stopScan();
    } catch (e, st) {
      debugPrint('stopScan failed pre-navigate: $e\n$st');
    }
    await _navigateToControl(devices);
  }

  /// Pushes ControlScreen for the given devices and, on return, restarts
  /// scanning for the next pick. Saves the device set to
  /// remembered-storage via the ControlScreen `onAnyConnected` callback,
  /// which fires only after the first member verifiably reaches
  /// `isReady` — so a Connect-tap that fails on every device (e.g. they're
  /// all out of range) never poisons the warm-start fast path. Shared
  /// between the manual "Connect (N)" tap and the auto-connect-on-cold-
  /// start path.
  Future<void> _navigateToControl(List<DeviceRef> devices) async {
    if (!mounted) return;
    void rememberOnConnect() => unawaited(
          widget.preferences.setRememberedDeviceIds(
            [for (final d in devices) d.id],
          ),
        );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) =>
            widget.controlScreenBuilder?.call(
              ctx,
              devices,
              rememberOnConnect,
            ) ??
            ControlScreen(
              devices: devices,
              preferences: widget.preferences,
              onAnyConnected: rememberOnConnect,
            ),
      ),
    );
    if (!mounted) return;
    // _checking may still be true if we entered via the auto-connect path —
    // flip it now so the scan UI replaces the spinner.
    setState(() {
      _selected.clear();
      _checking = false;
    });
    _startScan();
  }

  @override
  void dispose() {
    // Best-effort: dispose can't await, and a plugin-channel failure here
    // would be a useless crash since we're tearing down anyway. Both the
    // synchronous getter and the async future are guarded.
    try {
      if (_scanner.isScanningNow) {
        unawaited(_scanner.stopScan().catchError((_) {}));
      }
    } catch (_) {}
    super.dispose();
  }

  bool _isJaxJox(String name) {
    if (name.isEmpty) return false;
    if (name.endsWith('U')) return false; // DFU mode
    return kJaxJoxNamePrefixes.any(name.startsWith);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      // Brief frame-or-two flash while the async permission check resolves.
      // On miss we [pushReplacement] to PermissionScreen, so this never
      // becomes a stuck state.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZombieJox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(preferences: widget.preferences),
              ),
            ),
          ),
          StreamBuilder<bool>(
            stream: _scanner.isScanning,
            initialData: false,
            builder: (context, snap) => IconButton(
              icon: Icon(snap.data == true ? Icons.stop : Icons.refresh),
              onPressed: () async {
                if (snap.data == true) {
                  await _scanner.stopScan();
                } else {
                  await _startScan();
                }
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<ScanHit>>(
              stream: _scanner.results,
              initialData: const [],
              builder: (context, snap) {
                final results = (snap.data ?? const <ScanHit>[])
                    .where((r) => _isJaxJox(r.device.name))
                    .toList();
                return ScanResultsList(
                  results: results,
                  selected: _selected,
                  onToggle: _toggleSelected,
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _selected.isEmpty ? null : _onConnect,
                  child: Text(_selected.isEmpty
                      ? 'Connect'
                      : 'Connect (${_selected.length})'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders the live list of scan results with a checkbox per row. Pure UI:
/// owns no state, doesn't talk to any BLE plugin, and is what tests pump.
@visibleForTesting
class ScanResultsList extends StatelessWidget {
  final List<ScanHit> results;
  final Set<DeviceRef> selected;
  final ValueChanged<DeviceRef> onToggle;

  const ScanResultsList({
    super.key,
    required this.results,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const Center(child: Text('Scanning for JaxJox devices…'));
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) {
        final r = results[i];
        return CheckboxListTile(
          value: selected.contains(r.device),
          onChanged: (_) => onToggle(r.device),
          title: Text(r.device.name),
          subtitle: Text('${r.device.id}  •  RSSI ${r.rssi}'),
        );
      },
    );
  }
}
