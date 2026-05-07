import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/uuids.dart';
import '../state/preferences.dart';
import 'control_screen.dart';

class ScanScreen extends StatefulWidget {
  final Preferences preferences;

  const ScanScreen({super.key, required this.preferences});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _permissionsGranted = false;
  bool _checking = true;
  final Set<BluetoothDevice> _selected = <BluetoothDevice>{};

  @override
  void initState() {
    super.initState();
    _ensurePermissions();
  }

  Future<void> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final granted = statuses[Permission.bluetoothScan]?.isGranted == true &&
        statuses[Permission.bluetoothConnect]?.isGranted == true;
    if (!mounted) return;
    setState(() {
      _permissionsGranted = granted;
      _checking = false;
    });
    if (granted) {
      _startScan();
    }
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_permissionsGranted) {
      return Scaffold(
        appBar: AppBar(title: const Text('ZombieJox')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                    'Bluetooth permission is required to find your dumbbells.'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _ensurePermissions,
                  child: const Text('Grant permission'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('ZombieJox'),
        actions: [
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
