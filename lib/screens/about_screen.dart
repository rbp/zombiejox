import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// About screen. Static content: who built this, what it's for, what it
/// runs on top of. Reachable from Settings.
///
/// Layout:
///   1. Logo + app name + tagline at the top.
///   2. "What it is" pitch.
///   3. GitHub link + "Created by Rodrigo Pimentel \<rbp@isnomore.net\>"
///      — both rows hand off to the OS via `url_launcher`. The GitHub
///      row is fully tappable; on the author row only the email span is.
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
    final launch = launchUri ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication);
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
              //
              // cacheWidth / cacheHeight: the source PNG is 1024×1024
              // but it's displayed at 120 logical px. Without the
              // hints, Flutter would decode the full 1024² into memory
              // (~4 MB ARGB) and pay the CPU/GC cost on every About
              // open. Decode to device-pixel-exact size instead.
              Center(
                child: Builder(
                  builder: (context) {
                    final dpr = MediaQuery.devicePixelRatioOf(context);
                    final decoded = (120 * dpr).round();
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        'assets/icon-1024.png',
                        width: 120,
                        height: 120,
                        cacheWidth: decoded,
                        cacheHeight: decoded,
                      ),
                    );
                  },
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
                // `_open` is async; the VoidCallback expects void. Wrap
                // in `unawaited` so the discarded Future is intentional
                // (matches the HomeScreen pattern).
                onTap: () => unawaited(_open(context, _repoUri)),
              ),
              _AuthorLine(
                color: scheme.primary,
                onTapEmail: () => unawaited(_open(context, _authorEmailUri)),
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

/// "Created by Rodrigo Pimentel \<rbp@isnomore.net\>" with ONLY the
/// email span tappable — the surrounding text and the leading person
/// icon are inert. Uses [WidgetSpan] + [InkWell] (rather than
/// `Text.rich` + `TapGestureRecognizer`) so we don't have to manage the
/// recognizer's lifecycle from a parent state.
class _AuthorLine extends StatelessWidget {
  final Color color;
  final VoidCallback onTapEmail;

  const _AuthorLine({required this.color, required this.onTapEmail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = theme.textTheme.bodyMedium ?? const TextStyle();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.person_outline,
            size: 20,
            color: baseStyle.color?.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: baseStyle,
                children: [
                  const TextSpan(text: 'Created by Rodrigo Pimentel '),
                  // Wrap the whole `<email>` group in a single outer
                  // WidgetSpan so the line breaker treats it as one
                  // atomic placeholder — narrow widths wrap at the space
                  // before this span instead of orphaning `<` or `>`.
                  // Only the inner InkWell is tappable; the brackets stay inert.
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: Text.rich(
                      TextSpan(
                        style: baseStyle,
                        children: [
                          const TextSpan(text: '<'),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: Tooltip(
                              message: 'Email the author',
                              child: InkWell(
                                onTap: onTapEmail,
                                borderRadius: BorderRadius.circular(4),
                                child: Text(
                                  'rbp@isnomore.net',
                                  style: TextStyle(
                                    color: color,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const TextSpan(text: '>'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tappable row with an icon + label. Used for the GitHub link
/// where the entire label IS the target — see [_AuthorLine] for the
/// email case where only a single span inside the line should be
/// tappable.
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
