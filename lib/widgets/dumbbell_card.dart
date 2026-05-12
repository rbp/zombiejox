import 'package:flutter/material.dart';

import '../ble/ble_connection_state.dart';
import '../devices/dumbbell.dart';
import '../protocol/dumbbell_state.dart';
import '../state/weights.dart';

/// Per-device status card. Subscribes to a single [Dumbbell]'s connection +
/// state streams; renders name, status chip, current weight, motor state,
/// and battery.
///
/// Visual contract (PR 1 of the v1 design): same rounded-rect button-shaped
/// surface vocabulary as [WeightButton]. The status chip replaces the bare
/// bluetooth icon, so a quick glance at the card communicates state without
/// having to read the body text.
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
    return StreamBuilder<BleConnectionState>(
      stream: dumbbell.connectionState,
      builder: (context, connSnap) {
        final connected = connSnap.data == BleConnectionState.connected;
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
    final scheme = theme.colorScheme;
    final battery = state?.batteryPct;
    final motorActive = state?.motorActive ?? false;
    final weight = state == null ? '—' : formatWeight(state!.weightIndex, unit);

    final String statusLabel;
    final Color statusColor;
    if (!connected) {
      statusLabel = 'Connecting';
      statusColor = scheme.tertiary;
    } else if (motorActive) {
      statusLabel = 'Moving';
      statusColor = scheme.secondary;
    } else {
      statusLabel = 'Connected';
      statusColor = scheme.primary;
    }

    final bodyText = connected
        ? (motorActive ? 'Moving…' : 'Idle')
        : 'Connecting…';

    return Material(
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _StatusChip(label: statusLabel, color: statusColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    bodyText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: motorActive
                          ? scheme.secondary
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

/// Small pill that communicates connection state at a glance. Sized to be
/// readable next to the device name without crowding the row.
class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
