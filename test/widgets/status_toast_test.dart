import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/widgets/status_toast.dart';

/// Pump a host widget that owns an `Overlay` (via [MaterialApp.home] →
/// `Navigator` → `Overlay`) and surfaces a button that fires the toast
/// using the local [BuildContext]. The harness mirrors how the status
/// pill on `DumbbellCard` / `FailedDeviceCard` calls
/// [showStatusToast] in production.
Future<void> _pumpHost(WidgetTester tester, String message) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showStatusToast(context, message),
            child: const Text('fire'),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('shows the message after the fade-in completes', (tester) async {
    await _pumpHost(tester, 'Device AA:01 is Connected');
    await tester.tap(find.text('fire'));
    // Pump past the fade-in duration so the FadeTransition has settled
    // — at zero opacity the text would still be in the tree (a tap
    // before fade-in is invisible to the user but findable by tests),
    // so this assertion mirrors what the user sees.
    await tester.pump(kStatusToastFadeDuration);
    expect(find.text('Device AA:01 is Connected'), findsOneWidget);
  });

  testWidgets(
      'auto-dismisses: the overlay entry is removed after visible + '
      'fade-out durations', (tester) async {
    await _pumpHost(tester, 'auto-dismiss-me');
    await tester.tap(find.text('fire'));
    await tester.pump(kStatusToastFadeDuration);
    expect(find.text('auto-dismiss-me'), findsOneWidget);
    // Advance past visible-hold + fade-out + the microtask gap where
    // `await _controller.reverse()` resolves before `entry.remove()` runs.
    await tester.pump(kStatusToastVisibleDuration);
    await tester.pump(kStatusToastFadeDuration);
    // One extra pump so the OverlayEntry rebuild after `remove()` lands.
    await tester.pump();
    expect(find.text('auto-dismiss-me'), findsNothing,
        reason: 'toast must clean itself up; otherwise repeated taps '
            'would leak overlay entries');
  });

  testWidgets('does not intercept taps — the underlying button stays hot',
      (tester) async {
    // The toast is wrapped in IgnorePointer so a visible toast doesn't
    // eat taps on the cards / weight grid beneath it. Easiest test:
    // fire the toast, then while it's on screen, tap the same trigger
    // button again and confirm we get two toasts (the second tap was
    // registered).
    var fireCount = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () {
                fireCount++;
                showStatusToast(context, 'toast-$fireCount');
              },
              child: const Text('fire'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('fire'));
    await tester.pump(kStatusToastFadeDuration);
    expect(find.text('toast-1'), findsOneWidget);
    // Tap through — IgnorePointer makes the toast non-blocking.
    await tester.tap(find.text('fire'));
    await tester.pump(kStatusToastFadeDuration);
    expect(fireCount, 2, reason: 'toast must not block taps on the host UI');
    expect(find.text('toast-2'), findsOneWidget);
    // Drain the auto-dismiss timers so the test exits cleanly (each
    // toast: hold + fade-out + one frame for the OverlayEntry rebuild).
    await tester.pump(kStatusToastVisibleDuration);
    await tester.pump(kStatusToastFadeDuration);
    await tester.pump();
  });
}
