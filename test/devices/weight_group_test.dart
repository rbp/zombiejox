import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/ble/ble_connection_state.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/devices/dumbbell.dart';
import 'package:zombiejox/devices/weight_group.dart';
import 'package:zombiejox/protocol/dumbbell_state.dart';

/// Test double for [Dumbbell] that records calls and never touches BLE.
///
/// `Dumbbell`'s constructor wires up a `BleConnection` for `device` but does
/// no I/O at construction; overriding the public methods + the
/// [connectionState] getter keeps all tests hermetic (the production
/// getter would otherwise trip `flutter_blue_plus`'s platform-channel
/// check). State emissions are routed through a private broadcast
/// controller so we can drive the `WeightGroup`'s per-member listener.
class FakeDumbbell extends Dumbbell {
  FakeDumbbell(super.device, {this.startsReady = true});

  /// If true, `connect()` flips [isReady] to true automatically (the common
  /// case in tests). Set false to simulate a still-connecting dumbbell.
  final bool startsReady;
  bool _ready = false;

  final StreamController<DumbbellState> _states =
      StreamController<DumbbellState>.broadcast();
  final StreamController<BleConnectionState> _conn =
      StreamController<BleConnectionState>.broadcast();
  DumbbellState? _last;

  bool connectCalled = false;
  bool failConnect = false;
  Object connectError = StateError('fake connect failure');

  /// If set, `connect()` awaits this completer before returning. Lets a test
  /// hold a connect open while exercising other operations on the group.
  Completer<void>? _connectGate;

  /// If set, `reconnect()` awaits this completer before returning — lets
  /// the supervisor's `attempting` phase be observed before the next
  /// transition fires.
  Completer<void>? _reconnectGate;

  /// Counts every call to [reconnect] — drives the backoff-schedule
  /// assertions in the §2a reconnect tests.
  int reconnectCallCount = 0;

  /// When true, the next [reconnect] throws [reconnectError]. Tests use
  /// this to simulate the dumbbell still being out of range when a
  /// backoff timer fires.
  bool failReconnect = false;
  Object reconnectError = StateError('fake reconnect failure');

  final List<int> setWeightCalls = [];
  bool failSetWeight = false;
  Object setWeightError = StateError('fake set-weight failure');

  bool disconnectCalled = false;

  /// Mirror the real `Dumbbell.isReady` semantics: false after disconnect,
  /// reflects the state-arrival heuristic otherwise.
  @override
  bool get isReady => !disconnectCalled && _ready;

  @override
  Stream<DumbbellState> get states => _states.stream;

  @override
  Stream<BleConnectionState> get connectionState => _conn.stream;

  @override
  DumbbellState? get lastState => _last;

  /// Push a state through the broadcast controller, updating [lastState]
  /// first so consumers reading `lastState` from a snapshot see the new
  /// value. Also flips [_ready] so [isReady] tracks reality.
  void emitState(DumbbellState s) {
    _last = s;
    _ready = true;
    _states.add(s);
  }

  /// Simulate the dumbbell becoming ready without emitting a state
  /// frame — only useful for the disconnect-mid-add race; the production
  /// `Dumbbell` becomes ready via emitState().
  void becomeReady() {
    _ready = true;
  }

  /// Hold `connect()` open until [completeConnect] is called.
  void delayConnect() {
    _connectGate = Completer<void>();
  }

  void completeConnect() {
    final c = _connectGate;
    _connectGate = null;
    c?.complete();
  }

  /// Hold `reconnect()` open until [completeReconnect] is called.
  void delayReconnect() {
    _reconnectGate = Completer<void>();
  }

  void completeReconnect() {
    final c = _reconnectGate;
    _reconnectGate = null;
    c?.complete();
  }

  /// Simulate a mid-session BLE drop after the dumbbell has been ready:
  /// pushes a `disconnected` event on the conn stream and clears the
  /// state the WeightGroup supervisor will inspect (so `isReady` flips
  /// false synchronously and the next `setWeightIndex` skips this
  /// device). Mirrors what production `Dumbbell.handleTransportDrop`
  /// does internally.
  void simulateDrop() {
    _last = null;
    _ready = false;
    _conn.add(BleConnectionState.disconnected);
  }

  @override
  Future<void> connect() async {
    connectCalled = true;
    if (_connectGate != null) {
      await _connectGate!.future;
    }
    // failConnect is checked AFTER the gate so a test can hold connect
    // open, mutate `failConnect` mid-flight, then release — exercising
    // the failure-after-gate race window (e.g. WeightGroup.remove
    // running while connect is awaiting).
    if (failConnect) throw connectError;
    if (startsReady) _ready = true;
  }

  @override
  void handleTransportDrop() {
    // Match the production reset semantics on the fake's bookkeeping so
    // a subsequent `setWeightIndex` correctly skips this dumbbell.
    _last = null;
    _ready = false;
  }

  @override
  Future<void> reconnect() async {
    reconnectCallCount++;
    if (_reconnectGate != null) {
      await _reconnectGate!.future;
    }
    if (failReconnect) throw reconnectError;
    if (startsReady) _ready = true;
  }

  @override
  Future<void> setWeightIndex(int index) async {
    setWeightCalls.add(index);
    if (failSetWeight) throw setWeightError;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
    if (!_states.isClosed) await _states.close();
    if (!_conn.isClosed) await _conn.close();
  }
}

DeviceRef _device(String id) => DeviceRef(id: id);

void main() {
  group('add()', () {
    test('appends to snapshot.connected and calls connect()', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      await group.add(_device('AA:01'));

      expect(group.lastSnapshot.connected, hasLength(1));
      expect(group.lastSnapshot.connected.single, same(fakes.single));
      expect(group.lastSnapshot.failed, isEmpty);
      expect(fakes.single.connectCalled, isTrue);
    });

    test('emits a snapshot for each new member on the snapshots stream',
        () async {
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      final connectedLengths = <int>[];
      final sub = group.snapshots
          .listen((s) => connectedLengths.add(s.connected.length));

      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      await pumpEventQueue();

      // Two adds → at least one snapshot per add (with .connected
      // growing); the failed map stays empty throughout.
      expect(connectedLengths, containsAllInOrder([1, 2]));
      await sub.cancel();
    });

    test(
        'connect failure moves the device from connected to failed '
        '— without throwing out of add()', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d)..failConnect = true;
        fakes.add(f);
        return f;
      });

      // No throw — failure surfaces in the snapshot, not the future.
      await expectLater(group.add(_device('AA:01')), completes);

      expect(group.lastSnapshot.connected, isEmpty);
      expect(group.lastSnapshot.failed, hasLength(1));
      expect(group.lastSnapshot.failed[_device('AA:01')], isA<StateError>());
      // Best-effort cleanup ran: the would-be member was disconnect()ed.
      expect(fakes.single.disconnectCalled, isTrue);
    });

    test(
        'failed-add emits two snapshots — interim "connecting" then the '
        'failure with the device in `failed`', () async {
      final transitions = <(int, int)>[]; // (connected.length, failed.length)
      final group = WeightGroup(newDumbbell: (d) {
        return FakeDumbbell(d)..failConnect = true;
      });
      final sub = group.snapshots.listen(
          (s) => transitions.add((s.connected.length, s.failed.length)));

      await group.add(_device('AA:01'));
      await pumpEventQueue();

      // Member appears as connecting (1, 0), then moves to failed (0, 1).
      expect(transitions, [(1, 0), (0, 1)]);
      await sub.cancel();
    });

    test(
        'retry after failure drops the stale failed entry atomically with '
        'the new dumbbell appearing in connected', () async {
      var attempts = 0;
      final group = WeightGroup(newDumbbell: (d) {
        attempts++;
        // First attempt fails; second succeeds.
        return FakeDumbbell(d)..failConnect = (attempts == 1);
      });

      await group.add(_device('AA:01'));
      // Sanity: now in failed, not connected.
      expect(group.lastSnapshot.connected, isEmpty);
      expect(group.lastSnapshot.failed, hasLength(1));

      // Retry succeeds.
      await group.add(_device('AA:01'));
      expect(group.lastSnapshot.connected, hasLength(1));
      expect(group.lastSnapshot.failed, isEmpty,
          reason: 'stale failed entry must be cleared on retry success');
    });

    test('retry after failure that also fails replaces the failed entry',
        () async {
      final errors = [
        StateError('first failure'),
        StateError('second failure'),
      ];
      var attempts = 0;
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d)
          ..failConnect = true
          ..connectError = errors[attempts];
        attempts++;
        return f;
      });

      await group.add(_device('AA:01'));
      expect(group.lastSnapshot.failed[_device('AA:01')], same(errors[0]));

      await group.add(_device('AA:01'));
      expect(group.lastSnapshot.failed[_device('AA:01')], same(errors[1]),
          reason: 'second failure must replace the first');
    });

    test(
        'duplicate add for a device already in `connected` is a no-op '
        '— prevents two simultaneous connect() attempts to one peripheral',
        () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        // Hold each connect open so the first add is observably in
        // flight when the second add runs.
        final f = FakeDumbbell(d)..delayConnect();
        fakes.add(f);
        return f;
      });

      final first = group.add(_device('AA:01'));
      await pumpEventQueue();
      // First add has populated `connected` and is awaiting connect().
      expect(group.lastSnapshot.connected, hasLength(1));
      expect(fakes, hasLength(1));

      // Second add for the same device — must not spawn a new Dumbbell.
      await group.add(_device('AA:01'));
      expect(fakes, hasLength(1),
          reason: 'duplicate add must not construct a second Dumbbell');
      expect(group.lastSnapshot.connected, hasLength(1));

      // Release the first add to drain.
      fakes.single.completeConnect();
      await first;
    });
  });

  group('snapshot field derivations', () {
    test('consensusIndex is null with no ready members', () async {
      final group =
          WeightGroup(newDumbbell: (d) => FakeDumbbell(d, startsReady: false));
      await group.add(_device('AA:01'));
      expect(group.lastSnapshot.consensusIndex, isNull);
      expect(group.lastSnapshot.anyReady, isFalse);
      expect(group.lastSnapshot.anyMoving, isFalse);
    });

    test('all members agree → consensusIndex = the agreed weight', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      for (final f in fakes) {
        f.emitState(const DumbbellState(
            weightIndex: 3, motorActive: false, batteryPct: 80));
      }
      await pumpEventQueue();

      expect(group.lastSnapshot.consensusIndex, 3);
      expect(group.lastSnapshot.anyReady, isTrue);
      expect(group.lastSnapshot.anyMoving, isFalse);
    });

    test('members disagree → consensusIndex is null', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      fakes[0].emitState(const DumbbellState(
          weightIndex: 1, motorActive: false, batteryPct: 80));
      fakes[1].emitState(const DumbbellState(
          weightIndex: 2, motorActive: false, batteryPct: 80));
      await pumpEventQueue();

      expect(group.lastSnapshot.consensusIndex, isNull,
          reason: 'one disagreement breaks consensus');
    });

    test('anyMoving reflects motor activity across any ready member', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      fakes[0].emitState(const DumbbellState(
          weightIndex: 1, motorActive: false, batteryPct: 80));
      fakes[1].emitState(const DumbbellState(
          weightIndex: 1, motorActive: true, batteryPct: 80));
      await pumpEventQueue();

      expect(group.lastSnapshot.anyMoving, isTrue);
    });

    test('knownUnits aggregates unitRaw across ready members', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      await group.add(_device('AA:03'));
      fakes[0].emitState(const DumbbellState(
          weightIndex: 0, motorActive: false, batteryPct: 80, unitRaw: 0x00));
      fakes[1].emitState(const DumbbellState(
          weightIndex: 0, motorActive: false, batteryPct: 80, unitRaw: 0x00));
      fakes[2].emitState(const DumbbellState(
          weightIndex: 0, motorActive: false, batteryPct: 80, unitRaw: 0x01));
      await pumpEventQueue();

      // Two reported lbs (0x00), one reported kg (0x01) — set has both,
      // count is 3.
      expect(group.lastSnapshot.knownUnits, hasLength(2));
      expect(group.lastSnapshot.knownUnitCount, 3);
    });

    test('unknown unitRaw is excluded from knownUnits', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      // 0x42 is not a known unit byte.
      fakes.single.emitState(const DumbbellState(
          weightIndex: 0, motorActive: false, batteryPct: 80, unitRaw: 0x42));
      await pumpEventQueue();

      expect(group.lastSnapshot.knownUnits, isEmpty);
      expect(group.lastSnapshot.knownUnitCount, 0,
          reason: 'do not guess — unknown bytes must not contribute');
    });
  });

  group('snapshot stream timing', () {
    test('every state arrival emits a snapshot', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      final emissions = <int?>[];
      final sub =
          group.snapshots.listen((s) => emissions.add(s.consensusIndex));

      await group.add(_device('AA:01'));
      fakes.single.emitState(const DumbbellState(
          weightIndex: 4, motorActive: false, batteryPct: 80));
      // Let the snapshot stream propagate before the next state — real
      // dumbbells emit at ~1 Hz, not back-to-back synchronously. Without
      // this drain, the listener for state #1 fires after `_last` has
      // already advanced to state #2 (the fake updates `_last`
      // synchronously inside emitState), so both snapshots compute
      // consensusIndex from the latest value.
      await pumpEventQueue();
      fakes.single.emitState(const DumbbellState(
          weightIndex: 5, motorActive: false, batteryPct: 80));
      await pumpEventQueue();

      // Membership add (null), index=4 arrival (4), index=5 arrival (5).
      expect(emissions, [null, 4, 5]);
      await sub.cancel();
    });

    test('a duplicate state push does NOT re-emit (1 Hz 0xD2 dedupe)',
        () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      var emissionCount = 0;
      final sub = group.snapshots.listen((_) => emissionCount++);

      await group.add(_device('AA:01')); // emit #1
      const same =
          DumbbellState(weightIndex: 4, motorActive: false, batteryPct: 80);
      fakes.single.emitState(same); // emit #2
      fakes.single.emitState(same); // deduped — no emit
      fakes.single.emitState(same); // deduped — no emit
      await pumpEventQueue();

      expect(emissionCount, 2,
          reason: 'identical consecutive states must not churn the stream');
      await sub.cancel();
    });
  });

  group('setWeightIndex()', () {
    test('fans out to every ready member in parallel', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      await group.add(_device('AA:03'));

      await group.setWeightIndex(4);

      expect(fakes.length, 3);
      for (final f in fakes) {
        expect(f.setWeightCalls, [4]);
      }
    });

    test('on an empty group is a no-op (does not throw)', () async {
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      await expectLater(group.setWeightIndex(0), completes);
    });

    test('skips members that are not yet ready (race during connect window)',
        () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        // Simulate a dumbbell that's added to the group but whose connect
        // hasn't completed (and therefore whose TX char isn't initialized).
        final f = FakeDumbbell(d, startsReady: false);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      // fakes[0] is now in the group with isReady == false.

      // setWeightIndex during this window must not throw and must not
      // reach the not-yet-ready dumbbell.
      await expectLater(group.setWeightIndex(3), completes);
      expect(fakes[0].setWeightCalls, isEmpty);

      // Once ready, calls go through.
      fakes[0].becomeReady();
      await group.setWeightIndex(3);
      expect(fakes[0].setWeightCalls, [3]);
    });

    test('with a mix of ready and not-ready members, only ready ones receive',
        () async {
      final fakes = <FakeDumbbell>[];
      var i = 0;
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d, startsReady: i.isEven);
        i++;
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01')); // ready
      await group.add(_device('AA:02')); // NOT ready
      await group.add(_device('AA:03')); // ready

      await group.setWeightIndex(5);
      expect(fakes[0].setWeightCalls, [5]);
      expect(fakes[1].setWeightCalls, isEmpty);
      expect(fakes[2].setWeightCalls, [5]);
    });

    test('rethrows when any member fails', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      fakes[1].failSetWeight = true;

      await expectLater(
        group.setWeightIndex(2),
        throwsA(isA<StateError>()),
      );
      // The non-failing member should still have received the call.
      expect(fakes[0].setWeightCalls, [2]);
      expect(fakes[1].setWeightCalls, [2]);
    });
  });

  group('disconnectAll()', () {
    test('disconnects every member and clears all bookkeeping', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));

      await group.disconnectAll();

      expect(group.lastSnapshot.connected, isEmpty);
      expect(group.lastSnapshot.failed, isEmpty);
      for (final f in fakes) {
        expect(f.disconnectCalled, isTrue);
      }
    });

    test('emits an empty snapshot before closing the stream', () async {
      final connectedLengths = <int>[];
      var done = false;
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      group.snapshots.listen(
        (s) => connectedLengths.add(s.connected.length),
        onDone: () => done = true,
      );
      await group.add(_device('AA:01'));

      await group.disconnectAll();
      await pumpEventQueue();

      // 1 add → length 1; disconnectAll → length 0; then onDone fires.
      expect(connectedLengths, [1, 0]);
      expect(done, isTrue);
    });

    test('also clears `failed` entries on teardown', () async {
      final group =
          WeightGroup(newDumbbell: (d) => FakeDumbbell(d)..failConnect = true);
      await group.add(_device('AA:01'));
      expect(group.lastSnapshot.failed, hasLength(1));

      await group.disconnectAll();
      expect(group.lastSnapshot.failed, isEmpty,
          reason: 'teardown must not leave stale failed entries behind');
    });

    test('is idempotent', () async {
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      await group.add(_device('AA:01'));

      await group.disconnectAll();
      // A second call should be a quiet no-op (does not double-close streams).
      await expectLater(group.disconnectAll(), completes);
    });

    test(
        'fired during an in-flight add(): the racing dumbbell is disconnected '
        'via disconnectAll\'s snapshot iteration; the membership ends empty',
        () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        // Hold connect open so we can trigger disconnectAll mid-flight.
        f.delayConnect();
        fakes.add(f);
        return f;
      });

      // Start an add() but don't await — yields the loop so the dumbbell
      // gets pushed into the connected list before we tear down.
      final addFuture = group.add(_device('AA:01'));
      await pumpEventQueue();
      expect(group.lastSnapshot.connected, hasLength(1));

      // Tear down while connect is still pending. disconnectAll's snapshot
      // captures the in-flight dumbbell and calls Dumbbell.disconnect on
      // it directly — no special-case needed in WeightGroup.add.
      final disconnectFuture = group.disconnectAll();
      await pumpEventQueue();
      expect(fakes.single.disconnectCalled, isTrue);

      // Releasing the connect lets both futures resolve.
      fakes.single.completeConnect();
      await addFuture; // resolves successfully — the dumbbell handled itself
      await disconnectFuture;

      // No orphan: connected cleared, dumbbell disconnected.
      expect(group.lastSnapshot.connected, isEmpty);
      expect(group.lastSnapshot.failed, isEmpty);
      expect(fakes.single.disconnectCalled, isTrue);
    });
  });

  group('add() after disposal', () {
    test('throws StateError immediately', () async {
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      await group.disconnectAll();
      await expectLater(
        group.add(_device('AA:01')),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('remove()', () {
    test('drops a connected device + disconnects it + emits snapshot',
        () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      expect(group.lastSnapshot.connected, hasLength(2));

      await group.remove(_device('AA:01'));

      expect(group.lastSnapshot.connected, hasLength(1));
      expect(group.lastSnapshot.connected.single, same(fakes[1]));
      expect(fakes[0].disconnectCalled, isTrue,
          reason: 'removed dumbbell must be disconnected');
      expect(fakes[1].disconnectCalled, isFalse,
          reason: 'the other member must NOT be touched');
    });

    test('drops a failed entry without re-throwing', () async {
      final group =
          WeightGroup(newDumbbell: (d) => FakeDumbbell(d)..failConnect = true);
      await group.add(_device('AA:01'));
      expect(group.lastSnapshot.failed, hasLength(1));

      await group.remove(_device('AA:01'));
      expect(group.lastSnapshot.failed, isEmpty,
          reason: 'remove must clear the failed entry');
      expect(group.lastSnapshot.connected, isEmpty);
    });

    test(
        'against a device that is neither connected nor failed is a quiet '
        'no-op (does not emit a redundant snapshot)', () async {
      var emissions = 0;
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      final sub = group.snapshots.listen((_) => emissions++);
      await group.add(_device('AA:01'));
      final pre = emissions;

      await group.remove(_device('NEVER:SEEN'));
      await pumpEventQueue();

      expect(emissions, pre, reason: 'no membership change → no emission');
      await sub.cancel();
    });

    test('after disposal is a quiet no-op', () async {
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      await group.disconnectAll();
      await expectLater(group.remove(_device('AA:01')), completes);
    });

    test(
        'during an in-flight add(): the racing connect cannot resurrect the '
        'failed entry the user just dismissed', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d)..delayConnect();
        fakes.add(f);
        return f;
      });

      // Kick off an add() but don't await — yields the loop with the
      // dumbbell in `connected` and the connect awaiting our gate.
      final addFuture = group.add(_device('AA:01'));
      await pumpEventQueue();
      expect(group.lastSnapshot.connected, hasLength(1));

      // User taps × on the connecting card.
      await group.remove(_device('AA:01'));
      expect(group.lastSnapshot.connected, isEmpty);
      expect(group.lastSnapshot.failed, isEmpty);

      // Now arm a failure and release the gate. The catch block's race
      // guard sees `_stateSubs` no longer contains the dumbbell and
      // skips the failure-snapshot population.
      fakes.single.failConnect = true;
      fakes.single.completeConnect();
      await addFuture;
      await pumpEventQueue();

      expect(group.lastSnapshot.failed, isEmpty,
          reason: 'racing failure must not resurrect the dismissed slot');
      expect(fakes.single.disconnectCalled, isTrue);
    });
  });

  group('auto-reconnect on transport drop (§2a)', () {
    test(
        'triggers retry when a once-ready member drops; first attempt is '
        'immediate, success clears the retry state', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      fakes.single.emitState(const DumbbellState(
          weightIndex: 2, motorActive: false, batteryPct: 80));
      await pumpEventQueue();
      expect(group.lastSnapshot.anyReady, isTrue);

      fakes.single.simulateDrop();
      await pumpEventQueue();

      // First retry is immediate — reconnect() must have been called.
      expect(fakes.single.reconnectCallCount, greaterThanOrEqualTo(1),
          reason: 'backoff[0] is Duration.zero — fires on next tick');

      // The post-reconnect state arrival clears the retry entry.
      fakes.single.emitState(const DumbbellState(
          weightIndex: 2, motorActive: false, batteryPct: 80));
      await pumpEventQueue();

      expect(
        group.lastSnapshot.retryStates[const DeviceRef(id: 'AA:01')],
        isNull,
        reason: 'state arrival ⇒ retry cleared',
      );
      expect(group.lastSnapshot.anyReady, isTrue);
    });

    test(
        'drop on a member that never became ready does NOT trigger retry — '
        'that path is the existing _failed flow', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d, startsReady: false);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      // No emitState — fake stays not-ready. Now push a disconnect on
      // the conn stream as if the device went away mid-connect.
      fakes.single._conn.add(BleConnectionState.disconnected);
      await pumpEventQueue();

      expect(fakes.single.reconnectCallCount, 0,
          reason: 'never-ready ⇒ supervisor stays out of the way');
      expect(group.lastSnapshot.retryStates, isEmpty);
    });

    test(
        'connect failure (initial add path) goes to `failed`, not '
        '`retryStates` — retry supervision only kicks in post-ready', () async {
      final group = WeightGroup(newDumbbell: (d) {
        return FakeDumbbell(d)..failConnect = true;
      });
      await group.add(_device('AA:01'));
      await pumpEventQueue();

      expect(group.lastSnapshot.failed, hasLength(1));
      expect(group.lastSnapshot.retryStates, isEmpty);
    });

    test('drop emits a snapshot with retryStates entry for the device',
        () async {
      final emissions = <Map<DeviceRef, RetryState>>[];
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      final sub = group.snapshots.listen((s) => emissions.add(s.retryStates));
      await group.add(_device('AA:01'));
      fakes.single.emitState(const DumbbellState(
          weightIndex: 2, motorActive: false, batteryPct: 80));
      await pumpEventQueue();
      emissions.clear();

      // Hold the reconnect open so the supervisor's `waiting → attempting`
      // transition is observable in the emissions list.
      fakes.single.delayReconnect();
      fakes.single.simulateDrop();
      await pumpEventQueue();

      // At least one emission carries a non-empty retryStates with the
      // device present.
      final withRetry = emissions
          .where((m) => m[const DeviceRef(id: 'AA:01')] != null)
          .toList();
      expect(withRetry, isNotEmpty,
          reason: 'drop ⇒ supervisor emits a snapshot mentioning the slot');

      fakes.single.completeReconnect();
      await sub.cancel();
    });

    test(
        'backoff schedule: failed attempts trigger the documented '
        '0s, 2s, 5s sequence', () {
      // Margins are generous (~half a backoff step on either side of
      // each boundary) so the test is robust to fakeAsync's exact
      // "fires at <= elapsed-time" semantics without compromising what
      // it actually verifies: backoff[0] is immediate, backoff[1]=2s,
      // backoff[2]=5s.
      fakeAsync((async) {
        final fakes = <FakeDumbbell>[];
        final group = WeightGroup(newDumbbell: (d) {
          final f = FakeDumbbell(d)..failReconnect = true;
          fakes.add(f);
          return f;
        });
        unawaited(group.add(_device('AA:01')));
        async.flushMicrotasks();
        fakes.single.emitState(const DumbbellState(
            weightIndex: 2, motorActive: false, batteryPct: 80));
        async.flushMicrotasks();

        fakes.single.simulateDrop();
        async.flushMicrotasks();

        // backoff[0] = 0s — first attempt fires on the next event loop turn.
        async.elapse(const Duration(milliseconds: 100));
        expect(fakes.single.reconnectCallCount, 1,
            reason: 'attempt #1: backoff[0] = 0s');

        // 1.5s after #1 fired — backoff[1] = 2s, still waiting.
        async.elapse(const Duration(milliseconds: 1500));
        expect(fakes.single.reconnectCallCount, 1,
            reason: 'attempt #2 is gated by the 2s backoff');

        // Cross past 2s.
        async.elapse(const Duration(milliseconds: 1000));
        expect(fakes.single.reconnectCallCount, 2,
            reason: 'attempt #2 fires once 2s has elapsed');

        // 4s after #2 fired — backoff[2] = 5s, still waiting.
        async.elapse(const Duration(milliseconds: 4000));
        expect(fakes.single.reconnectCallCount, 2,
            reason: 'attempt #3 is gated by the 5s backoff');

        // Cross past 5s.
        async.elapse(const Duration(milliseconds: 2000));
        expect(fakes.single.reconnectCallCount, 3,
            reason: 'attempt #3 fires once 5s has elapsed');

        // Tear down so fakeAsync doesn't complain about pending timers.
        unawaited(group.disconnectAll());
        async.flushMicrotasks();
        async.flushTimers();
      });
    });

    test('remove() during a waiting backoff cancels the pending retry timer',
        () {
      fakeAsync((async) {
        final fakes = <FakeDumbbell>[];
        final group = WeightGroup(newDumbbell: (d) {
          final f = FakeDumbbell(d)..failReconnect = true;
          fakes.add(f);
          return f;
        });
        unawaited(group.add(_device('AA:01')));
        async.flushMicrotasks();
        fakes.single.emitState(const DumbbellState(
            weightIndex: 0, motorActive: false, batteryPct: 80));
        async.flushMicrotasks();

        fakes.single.simulateDrop();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1)); // attempt #1 fires
        async.flushMicrotasks();
        expect(fakes.single.reconnectCallCount, 1);

        // Now a 2s backoff is scheduled. Remove before it fires.
        unawaited(group.remove(_device('AA:01')));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 30));
        expect(fakes.single.reconnectCallCount, 1,
            reason: 'remove() must cancel the pending retry timer');
        async.flushTimers();
      });
    });

    test(
        'remove() during attempting: the racing reconnect future cannot '
        'resurrect the dismissed slot', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d)..delayReconnect();
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      fakes.single.emitState(const DumbbellState(
          weightIndex: 0, motorActive: false, batteryPct: 80));
      await pumpEventQueue();

      fakes.single.simulateDrop();
      await pumpEventQueue();
      // Immediate attempt is now gated on the reconnectGate.
      expect(fakes.single.reconnectCallCount, 1);

      await group.remove(_device('AA:01'));
      // Release the gate — reconnect resolves, but the supervisor's
      // _consumerStillCares check has already evicted the slot.
      fakes.single.completeReconnect();
      await pumpEventQueue();

      expect(group.lastSnapshot.connected, isEmpty,
          reason: 'remove + racing reconnect must not re-add the slot');
      expect(group.lastSnapshot.retryStates, isEmpty);
      expect(fakes.single.disconnectCalled, isTrue);
    });

    test('disconnectAll() cancels pending retry timers', () {
      fakeAsync((async) {
        final fakes = <FakeDumbbell>[];
        final group = WeightGroup(newDumbbell: (d) {
          final f = FakeDumbbell(d)..failReconnect = true;
          fakes.add(f);
          return f;
        });
        unawaited(group.add(_device('AA:01')));
        async.flushMicrotasks();
        fakes.single.emitState(const DumbbellState(
            weightIndex: 0, motorActive: false, batteryPct: 80));
        async.flushMicrotasks();
        fakes.single.simulateDrop();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1)); // attempt #1
        async.flushMicrotasks();
        expect(fakes.single.reconnectCallCount, 1);

        unawaited(group.disconnectAll());
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 60));
        expect(fakes.single.reconnectCallCount, 1,
            reason: 'disconnectAll must cancel the pending retry');
        async.flushTimers();
      });
    });

    test(
        'kickReconnectsForResume fast-forwards a waiting timer to fire '
        'immediately', () {
      fakeAsync((async) {
        final fakes = <FakeDumbbell>[];
        final group = WeightGroup(newDumbbell: (d) {
          final f = FakeDumbbell(d)..failReconnect = true;
          fakes.add(f);
          return f;
        });
        unawaited(group.add(_device('AA:01')));
        async.flushMicrotasks();
        fakes.single.emitState(const DumbbellState(
            weightIndex: 0, motorActive: false, batteryPct: 80));
        async.flushMicrotasks();
        fakes.single.simulateDrop();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1)); // attempt #1
        async.flushMicrotasks();
        expect(fakes.single.reconnectCallCount, 1);

        // Now a 2s backoff is waiting. Resume should bring it to 0s.
        group.kickReconnectsForResume();
        async.flushMicrotasks();
        expect(fakes.single.reconnectCallCount, 2,
            reason: 'resume kick fast-forwards the waiting timer');

        unawaited(group.disconnectAll());
        async.flushTimers();
      });
    });

    test(
        'kickReconnectsForResume does NOT interrupt an in-flight '
        'reconnect attempt', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d)..delayReconnect();
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      fakes.single.emitState(const DumbbellState(
          weightIndex: 0, motorActive: false, batteryPct: 80));
      await pumpEventQueue();
      fakes.single.simulateDrop();
      await pumpEventQueue();
      expect(fakes.single.reconnectCallCount, 1,
          reason: 'immediate attempt is gated on completeReconnect()');

      group.kickReconnectsForResume();
      await pumpEventQueue();

      expect(fakes.single.reconnectCallCount, 1,
          reason: 'resume kick must NOT race the in-flight reconnect');

      fakes.single.completeReconnect();
      await pumpEventQueue();
    });

    test(
        'a second `disconnected` event arriving during the `attempting` '
        'phase does NOT trigger a concurrent reconnect attempt', () async {
      // Defense-in-depth: the connectionState listener filters
      // `attempting` events out, and `_attemptReconnect` itself
      // double-checks. Verify both guards by emitting a stray
      // disconnect mid-reconnect.
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d)..delayReconnect();
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      fakes.single.emitState(const DumbbellState(
          weightIndex: 0, motorActive: false, batteryPct: 80));
      await pumpEventQueue();

      fakes.single.simulateDrop();
      await pumpEventQueue();
      // First attempt is in flight, gated on reconnectGate.
      expect(fakes.single.reconnectCallCount, 1);

      // Stray second disconnect (e.g. from the underlying _ble's
      // teardown emitting one more event before the swap completes).
      fakes.single._conn.add(BleConnectionState.disconnected);
      await pumpEventQueue();

      expect(fakes.single.reconnectCallCount, 1,
          reason: 'attempting-phase guards must suppress the duplicate');

      fakes.single.completeReconnect();
      await pumpEventQueue();
    });

    test(
        'setWeightIndex during reconnect skips the reconnecting member '
        'and reaches still-ready peers', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d)..delayReconnect();
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      for (final f in fakes) {
        f.emitState(const DumbbellState(
            weightIndex: 0, motorActive: false, batteryPct: 80));
      }
      await pumpEventQueue();

      // First fake drops; second stays ready.
      fakes[0].simulateDrop();
      await pumpEventQueue();
      expect(fakes[0].isReady, isFalse);
      expect(fakes[1].isReady, isTrue);

      await group.setWeightIndex(3);
      expect(fakes[0].setWeightCalls, isEmpty,
          reason: 'reconnecting member must not receive setWeightIndex');
      expect(fakes[1].setWeightCalls, [3],
          reason: 'ready peer must still receive setWeightIndex');

      fakes[0].completeReconnect();
      await pumpEventQueue();
    });
  });
}
