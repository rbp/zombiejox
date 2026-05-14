import 'package:flutter/material.dart';

import '../ble/device_ref.dart';
import 'rename_device_dialog.dart';
import 'status_toast.dart';

/// Card shown for a [DeviceRef] whose `connect()` threw. Visually matches
/// `DumbbellCard` but with an error-coloured "Failed" status chip, a
/// refresh icon for retrying, and a "×" icon for dismissing the slot.
///
/// Pure UI: takes the device, the error (rendered as a tooltip on the
/// refresh icon), an [onRetry] callback for the refresh tap, and an
/// [onRemove] callback for the "×" tap. Owning state lives on
/// `HomeScreen`.
class FailedDeviceCard extends StatelessWidget {
  final DeviceRef device;
  final Object error;
  final VoidCallback onRetry;

  /// Remove affordance — renders a small "×" close button alongside the
  /// refresh icon. HomeScreen passes a callback that drops the device
  /// from the WeightGroup's `failed` map and from its own selected list
  /// (useful when the user has no intention of retrying a particular
  /// failed connect).
  final VoidCallback onRemove;

  /// Resolved name to render — custom name when set, else
  /// `device.displayName`. Mirrors [DumbbellCard.displayName] so a
  /// rename made on the connected card carries over if the device
  /// fails to reconnect later.
  final String? displayName;

  /// User-set custom name (§2e), or `null` if absent. Drives the §2h
  /// status-pill toast: "Device $id ($customName) is Failed" when set,
  /// "Device $id is Failed" otherwise. Mirrors [DumbbellCard.customName].
  final String? customName;

  /// User tapped the name region to commit a rename. See
  /// [DumbbellCard.onRename] for semantics. When null, the name region
  /// is not tappable.
  final ValueChanged<String>? onRename;

  const FailedDeviceCard({
    super.key,
    required this.device,
    required this.error,
    required this.onRetry,
    required this.onRemove,
    this.displayName,
    this.customName,
    this.onRename,
  });

  Future<void> _handleRenameTap(BuildContext context, String name) async {
    final cb = onRename;
    if (cb == null) return;
    final result = await showRenameDeviceDialog(context, initialName: name);
    if (result == null) return;
    cb(result);
  }

  /// §2h: status-pill tap. State is always "Failed" for this card.
  void _handleStatusTap(BuildContext context) {
    final namePart =
        (customName != null && customName!.isNotEmpty) ? ' ($customName)' : '';
    showStatusToast(context, 'Device ${device.id}$namePart is Failed');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final errorColor = scheme.error;
    final name = displayName ?? device.displayName;
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
            // §2h: chip is tappable so a user can pull up the full
            // "Device $id ($name) is Failed" message — the pill itself
            // is fixed-width and may truncate on narrow phones. Keyed
            // so widget tests can target the tap region directly.
            //
            // Vertical Padding bumps the GestureDetector's opaque hit
            // area to the Material 48 dp minimum without enlarging
            // the visual chip. NOT `SizedBox + Center` — the chip's
            // private [_StatusChip] uses `alignment: Alignment.center`
            // with no explicit height, which would make it expand to
            // fill any tall parent and the `borderRadius: 999` would
            // round it into a near-circle. Mirrors the same wrapper
            // on [DumbbellCard].
            GestureDetector(
              key: const ValueKey('status-chip-tap'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _handleStatusTap(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: _StatusChip(label: 'Failed', color: errorColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: onRename == null
                        ? null
                        : () => _handleRenameTap(context, name),
                    borderRadius: BorderRadius.circular(4),
                    child: Text(
                      name,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Failed to connect',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: errorColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Try again — $error',
              onPressed: onRetry,
            ),
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
}

/// Mirrors the status chip used on the connected/connecting card so the
/// failed and live cards read as the same visual family. Kept private to
/// each file rather than shared — there are only two callsites, and the
/// "shared widget" wouldn't yet pay for its own file.
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      constraints: const BoxConstraints(maxWidth: 64, minWidth: 64),
      alignment: Alignment.center,
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
          fontSize: fontSize,
        ),
      ),
    );
  }
}
