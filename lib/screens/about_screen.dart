import 'package:flutter/material.dart';

/// About screen. Static content: who built this, what it's for, what it
/// runs on top of. Reachable from Settings.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Text('ZombieJox', style: theme.textTheme.displaySmall),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Your JaxJox dumbbells aren\'t dead. They just need a new brain.',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 32),
          Text('What it is', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Open-source Flutter replacement for the discontinued JaxJox '
            'Connect app. ZombieJox controls JaxJox DumbbellConnect (and '
            'eventually other JaxJox products) over Bluetooth. No cloud, no '
            'account, no telemetry.',
          ),
          const SizedBox(height: 24),
          Text('Credits', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            '• Eamon Tuhami / X8IQ LTD — proved the protocol was workable '
            'with the iOS-only "JaxJox Connect" app.',
          ),
          const SizedBox(height: 4),
          const Text(
            '• The original JaxJox engineering team — the hardware is solid; '
            'sorry the company didn\'t make it.',
          ),
          const SizedBox(height: 24),
          Text('Protocol', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const SelectableText(
            'The BLE protocol was reverse-engineered from the original '
            'Android APK and the libfitness.so native library. Full reference: '
            'docs/ble_protocol.md in the project repo.',
          ),
          const SizedBox(height: 24),
          Text('License', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const SelectableText(
            'Licensed under GPLv3. See COPYING in the project repo for the '
            'full license text.',
          ),
          const SizedBox(height: 24),
          Text('Disclaimer', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'ZombieJox is not affiliated with JaxJox, its administrators, or '
            'any successor entity. Provided as-is, no warranty.',
          ),
        ],
      ),
    );
  }
}
