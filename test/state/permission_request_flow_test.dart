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
