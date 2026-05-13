import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// About screen. Static content: who built this, what it's for, what it
/// runs on top of. Reachable from Settings.
///
/// Layout (§2c of IMPLEMENTATION_PLAN.md):
///   1. Logo + app name + tagline at the top.
///   2. "What it is" pitch.
///   3. GitHub link + "Rodrigo Pimentel \<rbp@isnomore.net\> started
///      this project." — both tappable rows that hand off to the OS via
///      `url_launcher`.
///   4. Credits / Protocol / License / Disclaimer.
class AboutScreen extends StatelessWidget {
  /// Override the URL launcher — used by widget tests to avoid the
  /// `url_launcher` platform channel and to assert on the URIs we
  /// hand to the OS. Production leaves this null and the screen calls
  /// `launchUrl(uri, mode: LaunchMode.externalApplication)`.
  final Future<bool> Function(Uri)? launchUri;

  const AboutScreen({super.key, this.launchUri});

  static final Uri _repoUri = Uri.parse('https://github.com/rbp/zombiejox');
  static final Uri _authorEmailUri = Uri.parse('mailto:rbp@isnomore.net');

  Future<void> _open(BuildContext context, Uri uri) async {
    final launch = launchUri ??
        (u) => launchUrl(u, mode: LaunchMode.externalApplication);
    bool ok;
    try {
      ok = await launch(uri);
    } catch (_) {
      ok = false;
    }
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $uri')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // Logo above app name. The PNG is the cream-background app
              // icon — same image the launcher uses — clipped to a
              // rounded rectangle so it reads as an icon, not a banner.
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/icon-1024.png',
                    width: 120,
                    height: 120,
                  ),
                ),
              ),
              const SizedBox(height: 16),
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
              const SizedBox(height: 16),
              _LinkRow(
                icon: Icons.code,
                label: 'github.com/rbp/zombiejox',
                tooltip: 'Open the project on GitHub',
                color: scheme.primary,
                onTap: () => _open(context, _repoUri),
              ),
              _LinkRow(
                icon: Icons.person_outline,
                label: 'Rodrigo Pimentel <rbp@isnomore.net> started this project.',
                tooltip: 'Email the author',
                color: scheme.primary,
                onTap: () => _open(context, _authorEmailUri),
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
        ),
      ),
    );
  }
}

/// One tappable row with an icon + label. Shared shape for the GitHub
/// link and the "started by" line so they read as a related pair.
class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _LinkRow({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
