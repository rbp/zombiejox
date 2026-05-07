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
