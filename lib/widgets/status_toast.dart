import 'dart:async';

import 'package:flutter/material.dart';

/// How long the toast stays at full opacity before fading out.
const Duration kStatusToastVisibleDuration = Duration(milliseconds: 1600);

/// Fade-in / fade-out duration. Same value used both ways so the
/// animation feels symmetric.
const Duration kStatusToastFadeDuration = Duration(milliseconds: 200);

/// Show a brief, centered "toast" overlay (§2h). The toast fades in,
/// holds for [kStatusToastVisibleDuration], then fades out and removes
/// itself from the [Overlay]. Non-blocking — wrapped in [IgnorePointer]
/// so the user can still interact with whatever's underneath.
///
/// Used by the status pill on [DumbbellCard] / [FailedDeviceCard]: the
/// pill is fixed-width and may truncate ("Conne…"), so tapping it surfaces
/// the full state plus the device id. SnackBar would jump the bottom of
/// the screen and feel heavy for what is effectively an inspect-affordance.
void showStatusToast(BuildContext context, String message) {
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _StatusToast(
      message: message,
      onDismissed: () {
        // OverlayEntry.remove() throws on a double-call; the toast widget
        // calls [onDismissed] exactly once at the end of its fade-out.
        entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

class _StatusToast extends StatefulWidget {
  final String message;
  final VoidCallback onDismissed;

  const _StatusToast({required this.message, required this.onDismissed});

  @override
  State<_StatusToast> createState() => _StatusToastState();
}

class _StatusToastState extends State<_StatusToast>
    with SingleTickerProviderStateMixin {
  // One controller, one animation, three phases driven by a
  // TweenSequence: fade-in → hold-at-1 → fade-out. No `Timer` —
  // a `Timer` scheduled inside an animation status listener never
  // fires under `tester.pump()` (the FakeAsync zone enqueues it but
  // the binding's pump only drives transient frame callbacks). Going
  // entirely through SchedulerBinding's frame loop keeps the toast
  // lifecycle test-pumpable end-to-end, AND makes
  // [kStatusToastVisibleDuration] the actual full-opacity hold —
  // not "fade-in + hold" as it was when the timer started at insertion.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kStatusToastFadeDuration +
        kStatusToastVisibleDuration +
        kStatusToastFadeDuration,
  );
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    final fadeMs = kStatusToastFadeDuration.inMilliseconds;
    final holdMs = kStatusToastVisibleDuration.inMilliseconds;
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: 1)
            .chain(CurveTween(curve: Curves.fastOutSlowIn)),
        weight: fadeMs.toDouble(),
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1),
        weight: holdMs.toDouble(),
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1, end: 0)
            .chain(CurveTween(curve: Curves.fastOutSlowIn)),
        weight: fadeMs.toDouble(),
      ),
    ]).animate(_controller);
    _controller.addStatusListener(_onComplete);
    unawaited(_controller.forward());
  }

  void _onComplete(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted) return;
    widget.onDismissed();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Positioned.fill + Center so the toast sits in the middle of the
    // screen regardless of which subtree triggered it. IgnorePointer so a
    // visible toast doesn't eat taps on the cards / weight grid below.
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _opacity,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Material(
                elevation: 6,
                color: scheme.inverseSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  // `liveRegion: true` so screen readers announce the
                  // message when it appears. Without this the toast
                  // is silent for AT users — the chip is tappable but
                  // the response (the toast text) never reaches them
                  // before the auto-dismiss removes it from the tree.
                  // `container: true` so the announcement is one
                  // coherent unit rather than a stream of glyphs.
                  child: Semantics(
                    container: true,
                    liveRegion: true,
                    child: Text(
                      widget.message,
                      style: TextStyle(color: scheme.onInverseSurface),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
