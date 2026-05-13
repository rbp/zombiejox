import 'package:flutter/material.dart';

import '../ble/ble_connection_state.dart';
import '../devices/dumbbell.dart';
import '../devices/weight_group.dart' show RetryState;
import '../protocol/dumbbell_state.dart';
import '../state/weights.dart';
import 'rename_device_dialog.dart';

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

  /// User-chosen display name override (§2e). When null, the card
  /// falls back to `dumbbell.device.displayName`. HomeScreen passes
  /// the value resolved through [SelectionModel.displayNameFor] so a
  /// renamed dumbbell shows the user's name on the card.
  final String? displayName;

  /// User tapped the name region to commit a rename. Receives the
  /// raw input string (caller is responsible for trim / empty
  /// handling — `SelectionModel.rename` already centralizes that). When
  /// null, the name region is not tappable and no rename UI is
  /// surfaced — keeps the widget reusable in screens or tests that
  /// don't care about renaming.
  final ValueChanged<String>? onRename;

  const DumbbellCard({
    super.key,
    required this.dumbbell,
    required this.unit,
    required this.onRemove,
    this.retryState,
    this.displayName,
    this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    final name = displayName ?? dumbbell.device.displayName;
    return StreamBuilder<BleConnectionState>(
      stream: dumbbell.connectionState,
      builder: (context, connSnap) {
        return StreamBuilder<DumbbellState>(
          stream: dumbbell.states,
          initialData: dumbbell.lastState,
          builder: (context, stateSnap) {
            final state = stateSnap.data;
            return _Card(
              name: name,
              connState: connSnap.data,
              state: state,
              unit: unit,
              onRemove: onRemove,
              retryState: retryState,
              onRename: onRename,
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
  final ValueChanged<String>? onRename;

  const _Card({
    required this.name,
    required this.connState,
    required this.state,
    required this.unit,
    required this.onRemove,
    required this.retryState,
    required this.onRename,
  });

  Future<void> _handleRenameTap(BuildContext context) async {
    final cb = onRename;
    if (cb == null) return;
    final result =
        await showRenameDeviceDialog(context, initialName: name);
    if (result == null) return;
    cb(result);
  }

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
    // "Connected at the BLE layer but no protocol-level state has
    // arrived yet" reads the same as initial connecting from the user's
    // perspective — `isReady` is false either way, and the weight grid
    // stays disabled. Distinct from `disconnected` (which requires
    // having been ready) and `reconnecting` (supervisor-driven).
    // Without this, a half-responsive device (e.g. a depleted-battery
    // dock that briefly wakes its radio but doesn't reply to `0xD1`)
    // would render as "Idle" with an em-dash weight — misleading the
    // user into thinking the connection works.
    final connectingProto = !connected || state == null;
    final weight = state == null ? '—' : formatWeight(state!.weightIndex, unit);

    // Status priority:
    //   1. `reconnecting`: supervisor is mid-backoff or mid-attempt for
    //      this device. Same tertiary colour as initial Connecting —
    //      visually it IS a connect attempt, just preceded by a drop.
    //   2. `disconnected` (no retry state): drop without supervisor,
    //      shouldn't normally happen but kept as a defensive fallback
    //      so a future code path that bypasses [WeightGroup] doesn't
    //      lie to the user with "Reconnecting…" when nothing is.
    //   3. `connectingProto`: BLE link not yet up OR up but no state
    //      frame yet (half-responsive device case).
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
    } else if (connectingProto) {
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
    } else if (connectingProto) {
      bodyText = 'Connecting…';
    } else if (motorActive) {
      bodyText = 'Moving…';
    } else {
      bodyText = 'Idle';
    }

    // Show the activity glyph (a static `Icons.bluetooth_searching`)
    // whenever we don't have a known weight to display — i.e. no state
    // frame has arrived yet (initial Connecting, or supervisor-driven
    // Reconnecting which cleared `lastState` via
    // `Dumbbell.handleTransportDrop`). The right-hand cluster
    // alternates: glyph when we don't know the weight, weight value
    // when we do.
    //
    // Specifically NOT `connectingProto || reconnecting` — that would
    // include the defensive `disconnected` fallback (where `state !=
    // null` and a known weight is available), drowning out the known
    // value with a meaningless "we're working on it" glyph.
    final showActivityGlyph = state == null;

    // Body text colour mirrors the chip colour for reconnecting +
    // disconnected + moving; everything else uses the muted body-text
    // tone. Pulled out so `AnimatedDefaultTextStyle` can tween it.
    final Color bodyColor;
    if (reconnecting) {
      bodyColor = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6) ??
          scheme.onSurface;
    } else if (disconnected) {
      bodyColor = scheme.error;
    } else if (motorActive) {
      bodyColor = scheme.secondary;
    } else {
      bodyColor = theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6) ??
          scheme.onSurface;
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
                  // Name is a tappable rename affordance (§2e). The
                  // InkWell is always present so the widget tree stays
                  // structurally identical across the rename / no-rename
                  // case; when [onRename] is null, the tap is dead. An
                  // InkWell with `onTap: null` is visually identical to
                  // a plain Text — no ripple area is shown.
                  InkWell(
                    onTap: onRename == null
                        ? null
                        : () => _handleRenameTap(context),
                    borderRadius: BorderRadius.circular(4),
                    child: Text(
                      name,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 2),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.fastOutSlowIn,
                    style: (theme.textTheme.bodySmall ?? const TextStyle())
                        .copyWith(color: bodyColor),
                    // Cross-fade the body line when its content changes
                    // (Connecting… → Idle → Moving… etc.) — the colour
                    // is already tweening; tweening the text on top
                    // smooths the whole transition.
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, anim) =>
                          FadeTransition(opacity: anim, child: child),
                      child: Text(bodyText, key: ValueKey(bodyText)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Connecting-state glyph ↔ weight occupy the same slot —
                // fixed height so the column doesn't jump as the icon
                // appears/disappears. A static `bluetooth_searching`
                // glyph rather than an indeterminate
                // `CircularProgressIndicator`: the latter ticks
                // forever, which would deadlock widget tests'
                // `pumpAndSettle()`. The animation cue lives in the
                // chip + body text crossfades; this glyph just signals
                // "BLE activity here."
                SizedBox(
                  height: (theme.textTheme.titleLarge?.fontSize ?? 22) + 4,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: showActivityGlyph
                        ? Icon(
                            Icons.bluetooth_searching,
                            key: const ValueKey('connect-glyph'),
                            size: 22,
                            color: statusColor,
                          )
                        : Text(
                            weight,
                            key: ValueKey('weight-$weight'),
                            style: theme.textTheme.titleLarge,
                          ),
                  ),
                ),
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
///
/// Animated: the fill / border colour tween via `AnimatedContainer` and
/// the label cross-fades via `AnimatedSwitcher`. Net effect is that a
/// Connecting → Connected → Moving transition feels continuous rather
/// than three discrete flips.
class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fontSize = label.length <= 10
        ? (theme.textTheme.labelSmall?.fontSize ?? 12) * 0.9
        : theme.textTheme.labelSmall?.fontSize;
    const animDur = Duration(milliseconds: 200);
    return AnimatedContainer(
      duration: animDur,
      curve: Curves.fastOutSlowIn,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      constraints: const BoxConstraints(maxWidth: 64, minWidth: 64),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1),
      ),
      child: AnimatedDefaultTextStyle(
        duration: animDur,
        curve: Curves.fastOutSlowIn,
        style: (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: fontSize,
        ),
        child: AnimatedSwitcher(
          duration: animDur,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          // Per-label key so AnimatedSwitcher cross-fades on content
          // change. Without the key the same Text instance would be
          // re-used and the label would flip instantly.
          child: Text(
            label,
            key: ValueKey(label),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
