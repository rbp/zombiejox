import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/device_display.dart';
import '../devices/dumbbell.dart';
import '../protocol/dumbbell_state.dart';
import '../state/weights.dart';

/// Per-device status card. Subscribes to a single [Dumbbell]'s connection +
/// state streams; renders name, connection dot, current weight, motor state,
/// and battery.
class DumbbellCard extends StatelessWidget {
  final Dumbbell dumbbell;
  final WeightUnit unit;

  const DumbbellCard({
    super.key,
    required this.dumbbell,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BluetoothConnectionState>(
      stream: dumbbell.connectionState,
      builder: (context, connSnap) {
        final connected = connSnap.data == BluetoothConnectionState.connected;
        return StreamBuilder<DumbbellState>(
          stream: dumbbell.states,
          initialData: dumbbell.lastState,
          builder: (context, stateSnap) {
            final state = stateSnap.data;
            return _Card(
              name: dumbbell.device.displayName,
              connected: connected,
              state: state,
              unit: unit,
            );
          },
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  final String name;
  final bool connected;
  final DumbbellState? state;
  final WeightUnit unit;

  const _Card({
    required this.name,
    required this.connected,
    required this.state,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final battery = state?.batteryPct;
    final motorActive = state?.motorActive ?? false;
    final weight = state == null ? '—' : formatWeight(state!.weightIndex, unit);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: connected ? Colors.green : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    connected
                        ? (motorActive ? 'Moving…' : 'Idle')
                        : 'Connecting…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: motorActive
                          ? Colors.orange
                          : theme.textTheme.bodySmall?.color
                              ?.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(weight, style: theme.textTheme.titleLarge),
                if (battery != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_batteryIcon(battery), size: 16),
                      const SizedBox(width: 2),
                      Text('$battery%', style: theme.textTheme.bodySmall),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _batteryIcon(int pct) {
    if (pct >= 80) return Icons.battery_full;
    if (pct >= 50) return Icons.battery_5_bar;
    if (pct >= 20) return Icons.battery_3_bar;
    return Icons.battery_alert;
  }
}
