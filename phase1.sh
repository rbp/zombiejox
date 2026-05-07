#!/usr/bin/env bash
# Phase 1 Flutter scaffold for ZombieJox.
#
# Usage: from the repo root (the directory with README.md / docs/ / etc.):
#   bash setup-phase1.sh
#
# Creates branch phase1/flutter-scaffold, runs `flutter create`, writes all
# hand-written files, patches platform configs, runs pub get / analyze / test,
# and leaves everything staged. You commit yourself so your signing key is used.

set -euo pipefail

# ---------- preflight ----------
command -v flutter >/dev/null || { echo "error: flutter not on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not on PATH" >&2; exit 1; }
[ -d .git ]              || { echo "error: run from the repo root (no .git here)" >&2; exit 1; }
[ -f README.md ]         || { echo "error: README.md not found — wrong directory?" >&2; exit 1; }
[ ! -f pubspec.yaml ]    || { echo "error: pubspec.yaml already exists. Already scaffolded?" >&2; exit 1; }

if ! git diff --quiet HEAD ; then
  echo "error: working tree not clean. Commit or stash first." >&2
  exit 1
fi

# ---------- branch ----------
git checkout -b phase1/flutter-scaffold

# ---------- flutter create ----------
echo "==> flutter create"
flutter create --org net.isnomore.zombiejox --project-name zombiejox --platforms=android,ios .

# Boilerplate we don't want
rm -f test/widget_test.dart

mkdir -p lib/protocol lib/ble lib/devices lib/screens test/protocol

# ---------- pubspec.yaml ----------
cat > pubspec.yaml <<'PUBSPEC'
name: zombiejox
description: Open-source Flutter replacement for the discontinued JaxJox Connect app.
publish_to: 'none'
version: 0.1.0+1

environment:
  sdk: ^3.6.0

dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  flutter_blue_plus: ^2.3.1
  permission_handler: ^12.0.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
PUBSPEC

# ---------- lib/main.dart ----------
cat > lib/main.dart <<'DART'
import 'package:flutter/material.dart';

import 'screens/scan_screen.dart';

void main() {
  runApp(const ZombieJoxApp());
}

class ZombieJoxApp extends StatelessWidget {
  const ZombieJoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZombieJox',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ScanScreen(),
    );
  }
}
DART

# ---------- lib/protocol/checksum.dart ----------
cat > lib/protocol/checksum.dart <<'DART'
/// JaxJox BLE checksum, recovered from arm64 disassembly of `libfitness.so`
/// (`getChecksum` at offset 0x7f8). See `docs/ble_protocol.md` §6.
int jaxjoxChecksum(List<int> data) {
  if (data.isEmpty) return 0x3A;
  var sum = 0;
  for (final b in data) {
    sum += b;
  }
  return ((-sum) ^ 0x3A) & 0xFF;
}
DART

# ---------- lib/protocol/opcodes.dart ----------
cat > lib/protocol/opcodes.dart <<'DART'
/// JaxJox protocol opcodes. See `docs/ble_protocol.md` §4 and §5.
///
/// `0x27` is intentionally absent — sending it knocks the dumbbell offline.
/// Do not add it.
class Opcodes {
  Opcodes._();

  static const int syncTime = 0x08;
  static const int setUser = 0xC0;
  static const int queryStatus = 0xD1;
  static const int stateBroadcast = 0xD2;
  static const int historyChunk = 0xD3;
  static const int historyComplete = 0xD4;
  static const int setWeight = 0xD6;
}
DART

# ---------- lib/protocol/frame.dart ----------
cat > lib/protocol/frame.dart <<'DART'
import 'dart:typed_data';

import 'checksum.dart';

/// `[0xFF, length, opcode, ...payload, checksum]` — see `docs/ble_protocol.md` §3.
///
/// `length` is the total transmitted byte count (`payload.length + 4`).
Uint8List buildFrame(int opcode, List<int> payload) {
  final length = payload.length + 4;
  final pre = <int>[0xFF, length, opcode, ...payload];
  return Uint8List.fromList([...pre, jaxjoxChecksum(pre)]);
}

class ParsedFrame {
  final int opcode;
  final Uint8List payload;
  ParsedFrame(this.opcode, this.payload);
}

/// Returns null if the frame is malformed or has a bad checksum.
ParsedFrame? parseFrame(List<int> bytes) {
  if (bytes.length < 4) return null;
  if (bytes[0] != 0xFF) return null;
  final length = bytes[1];
  if (length != bytes.length) return null;
  final pre = bytes.sublist(0, bytes.length - 1);
  if (jaxjoxChecksum(pre) != bytes.last) return null;
  return ParsedFrame(bytes[2], Uint8List.fromList(bytes.sublist(3, bytes.length - 1)));
}
DART

# ---------- lib/protocol/dumbbell_state.dart ----------
cat > lib/protocol/dumbbell_state.dart <<'DART'
import 'frame.dart';
import 'opcodes.dart';

/// 0–7 → published JaxJox weight steps in pounds. See `docs/ble_protocol.md` §4.
const List<int> kWeightLbsByIndex = [8, 14, 20, 26, 32, 38, 44, 50];

/// `0xD1` byte 6 — motor active. `0x04` is "settled"; other values (e.g. `0x07`
/// in a query reply) mean the same thing for our purposes — not actively moving.
/// See `docs/ble_protocol.md` §5.
const int _motorActive = 0x0C;

class DumbbellState {
  final int weightIndex;
  final bool motorActive;
  final int? batteryPct;

  const DumbbellState({
    required this.weightIndex,
    required this.motorActive,
    this.batteryPct,
  });

  int get weightLbs => kWeightLbsByIndex[weightIndex];

  DumbbellState copyWith({int? weightIndex, bool? motorActive, int? batteryPct}) =>
      DumbbellState(
        weightIndex: weightIndex ?? this.weightIndex,
        motorActive: motorActive ?? this.motorActive,
        batteryPct: batteryPct ?? this.batteryPct,
      );
}

/// Apply a parsed RX frame to the running state. Returns null if the frame is
/// not state-bearing (e.g. set-weight ACK/NACK).
DumbbellState? applyFrame(DumbbellState? prev, ParsedFrame frame) {
  switch (frame.opcode) {
    case Opcodes.queryStatus: // 0xD1 — query reply or motor-state push
      if (frame.payload.length < 6) return prev;
      final idx = frame.payload[1];
      if (idx < 0 || idx >= kWeightLbsByIndex.length) return prev;
      final motion = frame.payload[3];
      final battery = frame.payload[4];
      return DumbbellState(
        weightIndex: idx,
        motorActive: motion == _motorActive,
        batteryPct: battery,
      );
    case Opcodes.stateBroadcast: // 0xD2 — periodic ~1 Hz
      if (frame.payload.length < 9) return prev;
      final idx = frame.payload[8]; // payload offset 8 == frame byte 11
      if (idx < 0 || idx >= kWeightLbsByIndex.length) return prev;
      return (prev ?? const DumbbellState(weightIndex: 0, motorActive: false))
          .copyWith(weightIndex: idx);
    default:
      return prev;
  }
}
DART

# ---------- lib/ble/uuids.dart ----------
cat > lib/ble/uuids.dart <<'DART'
/// UUIDs and name prefixes from `docs/ble_protocol.md` §1 and §2.
class JaxJoxUuids {
  JaxJoxUuids._();

  static const String service = 'aae28f00-71b5-42a1-8c3c-f9cf6ac969d0';
  static const String txCharacteristic = 'aae28f02-71b5-42a1-8c3c-f9cf6ac969d0';
  static const String rxCharacteristic = 'aae28f01-71b5-42a1-8c3c-f9cf6ac969d0';

  static const String batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
  static const String deviceInformationService = '0000180a-0000-1000-8000-00805f9b34fb';
}

/// Advertised-name prefixes by product. Filter scan results to these.
/// Names ending in `U` are firmware-update mode; skip them.
const Map<String, String> kJaxJoxNamePrefixes = {
  'DumbbellConnect': 'DB200',
  'KettlebellConnect 2.0': 'KB200',
  'KettlebellConnect (legacy)': 'KB42',
  'PushUpConnect': 'PB220',
  'FoamRollerConnect': 'FR100',
};
DART

# ---------- lib/ble/ble_service.dart ----------
cat > lib/ble/ble_service.dart <<'DART'
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'uuids.dart';

/// Thin wrapper over `flutter_blue_plus`. Connects, finds the JaxJox custom
/// service, and exposes RX notifications + a `writeTx` method.
class BleConnection {
  final BluetoothDevice device;
  late BluetoothCharacteristic _tx;
  late BluetoothCharacteristic _rx;

  StreamSubscription<List<int>>? _rxSub;
  final StreamController<List<int>> _rxController = StreamController.broadcast();

  Stream<List<int>> get rxStream => _rxController.stream;
  Stream<BluetoothConnectionState> get connectionState => device.connectionState;

  BleConnection(this.device);

  Future<void> connect() async {
    // License.free per the flutter_blue_plus LICENSE: ZombieJox is GPLv3
    // open-source community software for orphaned hardware (see README), not
    // a commercial product. Revisit if distribution model changes.
    await device.connect(license: License.free, autoConnect: false);

    final services = await device.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid.str.toLowerCase() == JaxJoxUuids.service,
      orElse: () => throw StateError('JaxJox service not found on ${device.remoteId}'),
    );
    _tx = svc.characteristics.firstWhere(
      (c) => c.uuid.str.toLowerCase() == JaxJoxUuids.txCharacteristic,
      orElse: () => throw StateError('TX characteristic not found'),
    );
    _rx = svc.characteristics.firstWhere(
      (c) => c.uuid.str.toLowerCase() == JaxJoxUuids.rxCharacteristic,
      orElse: () => throw StateError('RX characteristic not found'),
    );
    await _rx.setNotifyValue(true);
    _rxSub = _rx.onValueReceived.listen(_rxController.add);
  }

  Future<void> writeTx(List<int> bytes) =>
      _tx.write(bytes, withoutResponse: true);

  Future<int?> readBatteryLevel() async {
    final services = await device.discoverServices();
    final svc = services.where((s) => s.uuid.str.toLowerCase() == JaxJoxUuids.batteryService).firstOrNull;
    if (svc == null) return null;
    final c = svc.characteristics.where((c) => c.uuid.str.toLowerCase() == JaxJoxUuids.batteryLevel).firstOrNull;
    if (c == null) return null;
    final v = await c.read();
    return v.isEmpty ? null : v.first;
  }

  Future<void> disconnect() async {
    await _rxSub?.cancel();
    _rxSub = null;
    await _rxController.close();
    await device.disconnect();
  }
}
DART

# ---------- lib/devices/dumbbell.dart ----------
cat > lib/devices/dumbbell.dart <<'DART'
import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_service.dart';
import '../protocol/dumbbell_state.dart';
import '../protocol/frame.dart';
import '../protocol/opcodes.dart';

/// Drives a single DumbbellConnect (`DB200`) device.
class Dumbbell {
  final BleConnection _ble;

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  Stream<DumbbellState> get states => _states.stream;

  DumbbellState? _last;
  DumbbellState? get lastState => _last;

  Stream<BluetoothConnectionState> get connectionState => _ble.connectionState;

  StreamSubscription<List<int>>? _rxSub;

  Dumbbell(BluetoothDevice device) : _ble = BleConnection(device);

  Future<void> connect() async {
    await _ble.connect();
    _rxSub = _ble.rxStream.listen(_onBytes);
    await _ble.writeTx(buildFrame(Opcodes.queryStatus, const []));
    final battery = await _ble.readBatteryLevel();
    if (battery != null) {
      _last = (_last ?? const DumbbellState(weightIndex: 0, motorActive: false))
          .copyWith(batteryPct: battery);
      _states.add(_last!);
    }
  }

  Future<void> setWeightIndex(int index) {
    assert(index >= 0 && index < 8, 'weight index must be 0..7');
    return _ble.writeTx(buildFrame(Opcodes.setWeight, [index]));
  }

  Future<void> disconnect() async {
    await _rxSub?.cancel();
    _rxSub = null;
    await _ble.disconnect();
    await _states.close();
  }

  void _onBytes(List<int> bytes) {
    final frame = parseFrame(bytes);
    if (frame == null) return;
    final next = applyFrame(_last, frame);
    if (next != null) {
      _last = next;
      _states.add(next);
    }
  }
}
DART

# ---------- lib/screens/scan_screen.dart ----------
cat > lib/screens/scan_screen.dart <<'DART'
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/uuids.dart';
import 'dumbbell_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

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
      MaterialPageRoute(builder: (_) => DumbbellScreen(device: device)),
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
                const Text('Bluetooth permission is required to find your dumbbells.'),
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
DART

# ---------- lib/screens/dumbbell_screen.dart ----------
cat > lib/screens/dumbbell_screen.dart <<'DART'
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../devices/dumbbell.dart';
import '../protocol/dumbbell_state.dart';

class DumbbellScreen extends StatefulWidget {
  final BluetoothDevice device;
  const DumbbellScreen({super.key, required this.device});

  @override
  State<DumbbellScreen> createState() => _DumbbellScreenState();
}

class _DumbbellScreenState extends State<DumbbellScreen> {
  late final Dumbbell _dumbbell;
  Object? _connectError;

  @override
  void initState() {
    super.initState();
    _dumbbell = Dumbbell(widget.device);
    _connect();
  }

  Future<void> _connect() async {
    try {
      await _dumbbell.connect();
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectError = e);
    }
  }

  @override
  void dispose() {
    _dumbbell.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.advName.isEmpty
            ? widget.device.remoteId.str
            : widget.device.advName),
      ),
      body: _connectError != null
          ? Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Connection failed: $_connectError'),
            ))
          : StreamBuilder<BluetoothConnectionState>(
              stream: _dumbbell.connectionState,
              builder: (context, connSnap) {
                final connected = connSnap.data == BluetoothConnectionState.connected;
                return StreamBuilder<DumbbellState>(
                  stream: _dumbbell.states,
                  builder: (context, snap) {
                    return _Body(
                      connected: connected,
                      state: snap.data,
                      onSelect: connected ? _dumbbell.setWeightIndex : null,
                    );
                  },
                );
              },
            ),
    );
  }
}

class _Body extends StatelessWidget {
  final bool connected;
  final DumbbellState? state;
  final Future<void> Function(int)? onSelect;

  const _Body({required this.connected, required this.state, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final weightLbs = state?.weightLbs;
    final battery = state?.batteryPct;
    final motorActive = state?.motorActive ?? false;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: connected ? Colors.green : Colors.grey),
              const SizedBox(width: 8),
              Text(connected ? 'Connected' : 'Connecting…'),
              const Spacer(),
              if (battery != null)
                Row(children: [
                  const Icon(Icons.battery_full),
                  Text(' $battery%'),
                ]),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: Column(children: [
              Text(
                weightLbs == null ? '—' : '$weightLbs lbs',
                style: Theme.of(context).textTheme.displayLarge,
              ),
              const SizedBox(height: 8),
              Text(motorActive ? 'Moving…' : 'Idle',
                  style: TextStyle(color: motorActive ? Colors.orange : Colors.grey)),
            ]),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: GridView.count(
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              children: [
                for (int i = 0; i < kWeightLbsByIndex.length; i++)
                  FilledButton.tonal(
                    onPressed: onSelect == null ? null : () => onSelect!(i),
                    child: Text('${kWeightLbsByIndex[i]} lbs'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
DART

# ---------- test/protocol/checksum_test.dart ----------
cat > test/protocol/checksum_test.dart <<'DART'
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/protocol/checksum.dart';

void main() {
  group('jaxjoxChecksum', () {
    test('worked example from docs/ble_protocol.md §6 (FF 05 D6 14 → 0x28)', () {
      expect(jaxjoxChecksum([0xFF, 0x05, 0xD6, 0x14]), 0x28);
    });

    test('empty input → 0x3A (per recovered algorithm)', () {
      expect(jaxjoxChecksum([]), 0x3A);
    });

    test('matches every published 0xD6 vector in §4', () {
      const vectors = [
        [[0xFF, 0x05, 0xD6, 0x00], 0x1C],
        [[0xFF, 0x05, 0xD6, 0x01], 0x1F],
        [[0xFF, 0x05, 0xD6, 0x02], 0x1E],
        [[0xFF, 0x05, 0xD6, 0x03], 0x19],
        [[0xFF, 0x05, 0xD6, 0x04], 0x18],
        [[0xFF, 0x05, 0xD6, 0x05], 0x1B],
        [[0xFF, 0x05, 0xD6, 0x06], 0x1A],
        [[0xFF, 0x05, 0xD6, 0x07], 0x25],
      ];
      for (final v in vectors) {
        expect(jaxjoxChecksum(v[0] as List<int>), v[1]);
      }
    });
  });
}
DART

# ---------- test/protocol/frame_test.dart ----------
cat > test/protocol/frame_test.dart <<'DART'
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/protocol/dumbbell_state.dart';
import 'package:zombiejox/protocol/frame.dart';
import 'package:zombiejox/protocol/opcodes.dart';

void main() {
  group('buildFrame', () {
    test('all eight 0xD6 set-weight golden vectors (docs §4)', () {
      const golden = [
        [0xFF, 0x05, 0xD6, 0x00, 0x1C],
        [0xFF, 0x05, 0xD6, 0x01, 0x1F],
        [0xFF, 0x05, 0xD6, 0x02, 0x1E],
        [0xFF, 0x05, 0xD6, 0x03, 0x19],
        [0xFF, 0x05, 0xD6, 0x04, 0x18],
        [0xFF, 0x05, 0xD6, 0x05, 0x1B],
        [0xFF, 0x05, 0xD6, 0x06, 0x1A],
        [0xFF, 0x05, 0xD6, 0x07, 0x25],
      ];
      for (var i = 0; i < golden.length; i++) {
        expect(buildFrame(Opcodes.setWeight, [i]), golden[i]);
      }
    });

    test('query-status frame is FF 04 D1 16', () {
      expect(buildFrame(Opcodes.queryStatus, const []), [0xFF, 0x04, 0xD1, 0x16]);
    });
  });

  group('parseFrame', () {
    test('round-trips a built frame', () {
      final bytes = buildFrame(Opcodes.setWeight, [3]);
      final parsed = parseFrame(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.opcode, 0xD6);
      expect(parsed.payload, [3]);
    });

    test('rejects bad checksum', () {
      expect(parseFrame([0xFF, 0x05, 0xD6, 0x03, 0x00]), isNull);
    });

    test('rejects bad length', () {
      expect(parseFrame([0xFF, 0x99, 0xD6, 0x03, 0x19]), isNull);
    });

    test('rejects missing leading 0xFF', () {
      expect(parseFrame([0x00, 0x05, 0xD6, 0x03, 0x19]), isNull);
    });
  });

  group('applyFrame / DumbbellState', () {
    test('decodes a settled motor-state push (docs §5)', () {
      final frame = parseFrame([0xFF, 0x0A, 0xD1, 0x00, 0x03, 0x64, 0x04, 0x64, 0x00, 0x6D]);
      expect(frame, isNotNull);
      final s = applyFrame(null, frame!);
      expect(s, isNotNull);
      expect(s!.weightIndex, 3);
      expect(s.weightLbs, 26);
      expect(s.motorActive, false);
      expect(s.batteryPct, 100);
    });

    test('decodes a motor-active push', () {
      final frame = parseFrame([0xFF, 0x0A, 0xD1, 0x00, 0x03, 0x64, 0x0C, 0x64, 0x00, 0x75]);
      final s = applyFrame(null, frame!);
      expect(s!.motorActive, true);
    });

    test('0xD2 broadcast updates weight index (docs §5)', () {
      final frame = parseFrame([0xFF, 0x10, 0xD2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x24]);
      final s = applyFrame(null, frame!);
      expect(s!.weightIndex, 1);
      expect(s.weightLbs, 14);
    });
  });
}
DART

# ---------- AndroidManifest.xml: insert BLE permissions, change app label ----------
python3 - <<'PY'
import pathlib
p = pathlib.Path('android/app/src/main/AndroidManifest.xml')
s = p.read_text()
perms = '''    <!-- BLE permissions: API 31+ uses BLUETOOTH_SCAN/CONNECT (no location);
         API 30 and below need ACCESS_FINE_LOCATION for scanning. -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
        android:maxSdkVersion="30" />
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />

    <application
        android:label="ZombieJox"'''
old = '    <application\n        android:label="zombiejox"'
if old not in s:
    raise SystemExit('AndroidManifest.xml: expected anchor not found; aborting')
p.write_text(s.replace(old, perms, 1))
PY

# ---------- android/app/build.gradle: pin minSdk = 21 ----------
python3 - <<'PY'
import pathlib
p = pathlib.Path('android/app/build.gradle.kts')
s = p.read_text()
old = 'minSdk = flutter.minSdkVersion'
new = '// flutter_blue_plus requires API 21+\n        minSdk = 21'
if old not in s:
    raise SystemExit('android/app/build.gradle.kts: expected anchor not found; aborting')
p.write_text(s.replace(old, new, 1))
PY

# ---------- ios/Runner/Info.plist: add NSBluetoothAlwaysUsageDescription ----------
python3 - <<'PY'
import pathlib
p = pathlib.Path('ios/Runner/Info.plist')
s = p.read_text()
old = '\t<key>CFBundleDisplayName</key>\n\t<string>Zombiejox</string>'
new = ('\t<key>CFBundleDisplayName</key>\n'
       '\t<string>ZombieJox</string>\n'
       '\t<key>NSBluetoothAlwaysUsageDescription</key>\n'
       '\t<string>ZombieJox uses Bluetooth to find and control your JaxJox dumbbells.</string>')
if old not in s:
    raise SystemExit('ios/Runner/Info.plist: expected anchor not found; aborting')
p.write_text(s.replace(old, new, 1))
PY

# ---------- .gitignore: add IDE noise patterns ----------
python3 - <<'PY'
import pathlib
p = pathlib.Path('.gitignore')
s = p.read_text() if p.exists() else ''
add = '\n# IDE / editor\n.idea/\n*.iml\n*.iws\n.metadata\n.vscode/\n'
if '.idea/' not in s:
    if not s.endswith('\n'):
        s += '\n'
    s += add
    p.write_text(s)
PY

# ---------- pub get / analyze / test ----------
echo "==> flutter pub get"
flutter pub get

echo "==> flutter analyze"
flutter analyze

echo "==> flutter test"
flutter test

# ---------- stage for review ----------
git add -A

echo
echo "Done. Changes are staged on branch phase1/flutter-scaffold."
echo "Review:  git status; git diff --cached"
echo "Commit:  git commit -m 'Phase 1: scaffold Flutter app with DumbbellConnect MVP'"