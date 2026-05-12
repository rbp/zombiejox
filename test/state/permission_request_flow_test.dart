import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/state/permission_request_flow.dart';

void main() {
  group('PermissionRequestFlow', () {
    test('starts in the rationale state', () {
      final flow = PermissionRequestFlow(request: () async => true);
      addTearDown(flow.dispose);
      expect(flow.state.value, PermissionFlowState.rationale);
    });

    test(
        'Continue + granted → returns true; mid-flight state is requesting; '
        'final state stays requesting because the caller is expected to '
        'navigate away', () async {
      final flow = PermissionRequestFlow(request: () async => true);
      addTearDown(flow.dispose);
      final transitions = <PermissionFlowState>[];
      flow.state.addListener(() => transitions.add(flow.state.value));

      final granted = await flow.requestPermissions();

      expect(granted, isTrue);
      expect(transitions, [PermissionFlowState.requesting]);
      expect(flow.state.value, PermissionFlowState.requesting);
    });

    test(
        'Continue + denied → returns false; transitions through requesting '
        'to denied', () async {
      final flow = PermissionRequestFlow(request: () async => false);
      addTearDown(flow.dispose);
      final transitions = <PermissionFlowState>[];
      flow.state.addListener(() => transitions.add(flow.state.value));

      final granted = await flow.requestPermissions();

      expect(granted, isFalse);
      expect(transitions,
          [PermissionFlowState.requesting, PermissionFlowState.denied]);
      expect(flow.state.value, PermissionFlowState.denied);
    });

    test(
        'a thrown exception from the request callback is treated as a '
        'denial — the user lands on the denied screen rather than seeing '
        'an uncaught async error', () async {
      final flow = PermissionRequestFlow(
        request: () async => throw Exception('platform channel oops'),
      );
      addTearDown(flow.dispose);

      final granted = await flow.requestPermissions();

      expect(granted, isFalse);
      expect(flow.state.value, PermissionFlowState.denied);
    });

    test(
        're-entrant requestPermissions while one is already in flight is a '
        'no-op — a stuck double-tap cannot double-prompt the OS', () async {
      final completer = Completer<bool>();
      final flow = PermissionRequestFlow(request: () => completer.future);
      addTearDown(flow.dispose);

      final first = flow.requestPermissions();
      expect(flow.state.value, PermissionFlowState.requesting);

      // Second call while the first is in flight returns false immediately
      // without touching state.
      final second = await flow.requestPermissions();
      expect(second, isFalse);
      expect(flow.state.value, PermissionFlowState.requesting);

      completer.complete(true);
      expect(await first, isTrue);
    });

    test(
        'requestPermissions from denied is a no-op — caller must call '
        'tryAgain first. The documented state machine has no direct '
        'denied → requesting edge', () async {
      var attempts = 0;
      final flow = PermissionRequestFlow(request: () async {
        attempts++;
        return false;
      });
      addTearDown(flow.dispose);

      await flow.requestPermissions();
      expect(flow.state.value, PermissionFlowState.denied);
      expect(attempts, 1);

      // Second call without tryAgain — must not re-prompt, state unchanged.
      final ok = await flow.requestPermissions();
      expect(ok, isFalse);
      expect(flow.state.value, PermissionFlowState.denied);
      expect(attempts, 1,
          reason: 'request callback must not have been invoked');
    });

    test('tryAgain returns from denied to rationale', () async {
      final flow = PermissionRequestFlow(request: () async => false);
      addTearDown(flow.dispose);

      await flow.requestPermissions();
      expect(flow.state.value, PermissionFlowState.denied);

      flow.tryAgain();
      expect(flow.state.value, PermissionFlowState.rationale);
    });

    test('tryAgain from rationale or requesting is a no-op', () async {
      final completer = Completer<bool>();
      final flow = PermissionRequestFlow(request: () => completer.future);
      addTearDown(flow.dispose);

      flow.tryAgain();
      expect(flow.state.value, PermissionFlowState.rationale,
          reason: 'tryAgain from rationale should not transition');

      final pending = flow.requestPermissions();
      flow.tryAgain();
      expect(flow.state.value, PermissionFlowState.requesting,
          reason: 'tryAgain must NOT cancel an in-flight request');

      completer.complete(false);
      await pending;
      expect(flow.state.value, PermissionFlowState.denied);
    });

    test(
        'requestPermissions resolving after dispose does not throw — the '
        'widget that owns the flow can unmount while the OS prompt is up',
        () async {
      final completer = Completer<bool>();
      final flow = PermissionRequestFlow(request: () => completer.future);

      final pending = flow.requestPermissions();
      expect(flow.state.value, PermissionFlowState.requesting);

      // Owner tears down while the prompt is still in flight.
      flow.dispose();

      // Both terminal arms of the await (denial value + thrown exception)
      // must short-circuit cleanly rather than writing to the disposed
      // ValueNotifier.
      completer.complete(false);
      final granted = await pending;
      expect(granted, isFalse);

      // After dispose, further calls are no-ops too.
      expect(await flow.requestPermissions(), isFalse);
      flow.tryAgain();
    });

    test(
        'dispose is idempotent — a second dispose call is a no-op rather '
        'than throwing on the already-disposed ValueNotifier', () {
      final flow = PermissionRequestFlow(request: () async => true);
      flow.dispose();
      flow.dispose(); // must not throw
    });

    test(
        'after tryAgain, a fresh requestPermissions runs as a new attempt '
        '— retry path works end-to-end', () async {
      var attempts = 0;
      final flow = PermissionRequestFlow(request: () async {
        attempts++;
        return attempts == 2; // deny first, grant second
      });
      addTearDown(flow.dispose);

      var granted = await flow.requestPermissions();
      expect(granted, isFalse);
      expect(flow.state.value, PermissionFlowState.denied);

      flow.tryAgain();
      expect(flow.state.value, PermissionFlowState.rationale);

      granted = await flow.requestPermissions();
      expect(granted, isTrue);
      expect(attempts, 2);
    });
  });
}
