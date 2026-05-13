import 'package:flutter/material.dart';

import '../ble/device_ref.dart';

/// Card shown for a [DeviceRef] whose `connect()` threw. Visually matches
/// `DumbbellCard` but with an error-coloured "Failed" status chip and a
/// refresh icon for retrying.
///
/// Pure UI: takes the device, the error (rendered as a tooltip on the
/// icon), and a retry callback. Owning state lives on `ControlScreen`.
class FailedDeviceCard extends StatelessWidget {
  final DeviceRef device;
  final Object error;
  final VoidCallback onRetry;

  const FailedDeviceCard({
    super.key,
    required this.device,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final errorColor = scheme.error;
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
            _StatusChip(label: 'Failed', color: errorColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.displayName,
                    style: theme.textTheme.titleMedium,
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
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Try again — $error',
              onPressed: onRetry,
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
