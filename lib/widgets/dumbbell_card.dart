import 'package:flutter/material.dart';

import '../ble/ble_connection_state.dart';
import '../devices/dumbbell.dart';
import '../devices/weight_group.dart' show RetryState;
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

  /// Remove affordance — renders the trailing "×" close button.
  /// HomeScreen passes a callback that removes the device from the
  /// `WeightGroup` and from its own selected list.
  final VoidCallback onRemove;

  /// Per-device reconnect state from the group snapshot, if the
  /// transport has dropped and a retry is pending or in flight. Drives
  /// the "Reconnecting…" status chip and body line; null means the
  /// dumbbell is in its normal lifecycle (initial connect, connected,
  /// motor active, or — fallback — a drop with no supervisor).
  final RetryState? retryState;

  const DumbbellCard({
    super.key,
    required this.dumbbell,
    required this.unit,
    required this.onRemove,
    this.retryState,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BleConnectionState>(
      stream: dumbbell.connectionState,
      builder: (context, connSnap) {
        return StreamBuilder<DumbbellState>(
          stream: dumbbell.states,
          initialData: dumbbell.lastState,
          builder: (context, stateSnap) {
            final state = stateSnap.data;
            return _Card(
              name: dumbbell.device.displayName,
              connState: connSnap.data,
              state: state,
              unit: unit,
              onRemove: onRemove,
              retryState: retryState,
            );
          },
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  final String name;
  final BleConnectionState? connState;
  final DumbbellState? state;
  final WeightUnit unit;
  final VoidCallback onRemove;
  final RetryState? retryState;

  const _Card({
    required this.name,
    required this.connState,
    required this.state,
    required this.unit,
    required this.onRemove,
    required this.retryState,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final battery = state?.batteryPct;
    final motorActive = state?.motorActive ?? false;
    final connected = connState == BleConnectionState.connected;
    // Gate the mid-session-drop UI on `state != null` — the underlying
    // BLE stream emits an initial `disconnected` value at subscription
    // time, before connect() has had a chance to resolve. Without this
    // guard a brand-new card would flash an error-coloured "Disconnected"
    // for one frame before settling into "Connecting…". `state != null`
    // is "the device has at some point reported a state frame", i.e.
    // "was once truly connected".
    final disconnected =
        connState == BleConnectionState.disconnected && state != null;
    final reconnecting = retryState != null;
    final weight = state == null ? '—' : formatWeight(state!.weightIndex, unit);

    // Status priority:
    //   1. `reconnecting`: supervisor is mid-backoff or mid-attempt for
    //      this device. Same tertiary colour as initial Connecting —
    //      visually it IS a connect attempt, just preceded by a drop.
    //   2. `disconnected` (no retry state): drop without supervisor,
    //      shouldn't normally happen but kept as a defensive fallback
    //      so a future code path that bypasses [WeightGroup] doesn't
    //      lie to the user with "Reconnecting…" when nothing is.
    //   3. Initial connecting (no state, not yet connected).
    //   4. Motor active.
    //   5. Connected, idle.
    final String statusLabel;
    final Color statusColor;
    if (reconnecting) {
      statusLabel = 'Reconnecting';
      statusColor = scheme.tertiary;
    } else if (disconnected) {
      statusLabel = 'Disconnected';
      statusColor = scheme.error;
    } else if (!connected) {
      statusLabel = 'Connecting';
      statusColor = scheme.tertiary;
    } else if (motorActive) {
      statusLabel = 'Moving';
      statusColor = scheme.secondary;
    } else {
      statusLabel = 'Connected';
      statusColor = scheme.primary;
    }

    final String bodyText;
    if (reconnecting) {
      bodyText = 'Reconnecting…';
    } else if (disconnected) {
      bodyText = 'Disconnected';
    } else if (!connected) {
      bodyText = 'Connecting…';
    } else if (motorActive) {
      bodyText = 'Moving…';
    } else {
      bodyText = 'Idle';
    }

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
                      color: !reconnecting && disconnected
                          ? scheme.error
                          : !reconnecting && motorActive
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
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Remove $name',
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
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
