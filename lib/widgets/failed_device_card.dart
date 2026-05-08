import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Card shown for a [BluetoothDevice] whose `connect()` threw. Visually
/// matches `DumbbellCard` but with an error-coloured "Failed to connect"
/// status line and a refresh icon for retrying.
///
/// Pure UI: takes the device, the optional error (rendered as a tooltip
/// on the icon), and a retry callback. Owning state lives on
/// `ControlScreen`.
class FailedDeviceCard extends StatelessWidget {
  final BluetoothDevice device;
  final Object? error;
  final VoidCallback? onRetry;

  const FailedDeviceCard({
    super.key,
    required this.device,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: errorColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _displayName(device),
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
              tooltip: error == null ? 'Try again' : 'Try again — $error',
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

String _displayName(BluetoothDevice device) {
  final adv = device.advName;
  if (adv.isNotEmpty) return adv;
  return device.remoteId.str;
}
