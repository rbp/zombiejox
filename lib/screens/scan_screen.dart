import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/uuids.dart';
import '../state/preferences.dart';
import 'control_screen.dart';
import 'permission_screen.dart';
import 'settings_screen.dart';

class ScanScreen extends StatefulWidget {
  final Preferences preferences;

  const ScanScreen({super.key, required this.preferences});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _checking = true;
  final Set<BluetoothDevice> _selected = <BluetoothDevice>{};

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
  Future<void> _ensurePermissions() async {
    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    final granted = scan.isGranted && connect.isGranted;
    if (!mounted) return;
    if (!granted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PermissionScreen(preferences: widget.preferences),
        ),
      );
      return;
    }
    setState(() => _checking = false);
    _startScan();
  }

  Future<void> _startScan() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    await FlutterBluePlus.startScan(
      withKeywords: kJaxJoxNamePrefixes.values.toList(),
      timeout: const Duration(seconds: 30),
    );
  }

  void _toggleSelected(BluetoothDevice device) {
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
    await FlutterBluePlus.stopScan();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ControlScreen(
          devices: devices,
          preferences: widget.preferences,
        ),
      ),
    );
    if (!mounted) return;
    setState(_selected.clear);
    _startScan();
  }

  @override
  void dispose() {
    if (FlutterBluePlus.isScanningNow) {
      FlutterBluePlus.stopScan();
    }
    super.dispose();
  }

  bool _isJaxJox(String name) {
    if (name.isEmpty) return false;
    if (name.endsWith('U')) return false; // DFU mode
    return kJaxJoxNamePrefixes.values.any(name.startsWith);
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
            stream: FlutterBluePlus.isScanning,
            initialData: false,
            builder: (context, snap) => IconButton(
              icon: Icon(snap.data == true ? Icons.stop : Icons.refresh),
              onPressed: () async {
                if (snap.data == true) {
                  await FlutterBluePlus.stopScan();
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
            child: StreamBuilder<List<ScanResult>>(
              stream: FlutterBluePlus.scanResults,
              initialData: const [],
              builder: (context, snap) {
                final results = (snap.data ?? const <ScanResult>[])
                    .where((r) => _isJaxJox(r.advertisementData.advName))
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
/// owns no state, doesn't talk to FlutterBluePlus, and is what tests pump.
@visibleForTesting
class ScanResultsList extends StatelessWidget {
  final List<ScanResult> results;
  final Set<BluetoothDevice> selected;
  final ValueChanged<BluetoothDevice> onToggle;

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
          title: Text(r.advertisementData.advName),
          subtitle: Text('${r.device.remoteId}  •  RSSI ${r.rssi}'),
        );
      },
    );
  }
}
