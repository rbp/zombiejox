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

  Future<void> _onTapDevice(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ControlScreen(
          devices: [device],
          preferences: widget.preferences,
        ),
      ),
    );
    if (mounted) _startScan();
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
      body: StreamBuilder<List<ScanResult>>(
        stream: FlutterBluePlus.scanResults,
        initialData: const [],
        builder: (context, snap) {
          final results = (snap.data ?? const <ScanResult>[])
              .where((r) => _isJaxJox(r.advertisementData.advName))
              .toList();
          if (results.isEmpty) {
            return const Center(child: Text('Scanning for JaxJox devices…'));
          }
          return ListView.builder(
            itemCount: results.length,
            itemBuilder: (_, i) {
              final r = results[i];
              return ListTile(
                title: Text(r.advertisementData.advName),
                subtitle: Text('${r.device.remoteId}  •  RSSI ${r.rssi}'),
                onTap: () => _onTapDevice(r.device),
              );
            },
          );
        },
      ),
    );
  }
}
