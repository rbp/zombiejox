import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/devices/dumbbell.dart';
import 'package:zombiejox/devices/weight_group.dart';

/// Test double for [Dumbbell] that records calls and never touches BLE.
///
/// `Dumbbell`'s constructor wires up a `BleConnection` for `device` but does
/// no I/O at construction; overriding the public methods keeps all tests
/// hermetic.
class FakeDumbbell extends Dumbbell {
  FakeDumbbell(super.device, {this.startsReady = true});

  /// If true, `connect()` flips [isReady] to true automatically (the common
  /// case in tests). Set false to simulate a still-connecting dumbbell.
  final bool startsReady;
  bool _ready = false;

  bool connectCalled = false;
  bool failConnect = false;
  Object connectError = StateError('fake connect failure');

  /// If set, `connect()` awaits this completer before returning. Lets a test
  /// hold a connect open while exercising other operations on the group.
  Completer<void>? _connectGate;

  final List<int> setWeightCalls = [];
  bool failSetWeight = false;
  Object setWeightError = StateError('fake set-weight failure');

  bool disconnectCalled = false;

  /// Mirror the real `Dumbbell.isReady` semantics: false after disconnect.
  @override
  bool get isReady => !disconnectCalled && _ready;

  /// Simulate the dumbbell becoming ready (state has arrived).
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

  @override
  Future<void> connect() async {
    connectCalled = true;
    if (failConnect) throw connectError;
    if (_connectGate != null) {
      await _connectGate!.future;
    }
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
  }
}

BluetoothDevice _device(String id) =>
    BluetoothDevice(remoteId: DeviceIdentifier(id));

void main() {
  group('add()', () {
    test('appends, returns the new dumbbell, calls connect()', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });

      final db = await group.add(_device('AA:01'));

      expect(group.dumbbells, hasLength(1));
      expect(group.dumbbells.single, same(db));
      expect(fakes.single.connectCalled, isTrue);
    });

    test('emits the new membership on the changes stream', () async {
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      final emissions = <int>[];
      final sub = group.changes.listen((list) => emissions.add(list.length));

      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));
      await pumpEventQueue();

      expect(emissions, [1, 2]);
      await sub.cancel();
    });

    test('removes the dumbbell from membership and rethrows when connect fails',
        () async {
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        f.failConnect = true;
        return f;
      });

      await expectLater(
        group.add(_device('AA:01')),
        throwsA(isA<StateError>()),
      );
      expect(group.dumbbells, isEmpty);
    });

    test('failed-add still emits an interim "connecting" membership', () async {
      final emissions = <int>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        f.failConnect = true;
        return f;
      });
      final sub = group.changes.listen((list) => emissions.add(list.length));

      try {
        await group.add(_device('AA:01'));
      } catch (_) {/* expected */}
      await pumpEventQueue();

      // First the device appears (length 1), then it's removed (length 0).
      expect(emissions, [1, 0]);
      await sub.cancel();
    });
  });

  group('setWeightIndex()', () {
    test('fans out to every member in parallel', () async {
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
    test('disconnects every member and clears membership', () async {
      final fakes = <FakeDumbbell>[];
      final group = WeightGroup(newDumbbell: (d) {
        final f = FakeDumbbell(d);
        fakes.add(f);
        return f;
      });
      await group.add(_device('AA:01'));
      await group.add(_device('AA:02'));

      await group.disconnectAll();

      expect(group.dumbbells, isEmpty);
      for (final f in fakes) {
        expect(f.disconnectCalled, isTrue);
      }
    });

    test('emits an empty membership before closing the changes stream',
        () async {
      final emissions = <int>[];
      final group = WeightGroup(newDumbbell: (d) => FakeDumbbell(d));
      group.changes.listen(
        (list) => emissions.add(list.length),
        onDone: () => emissions.add(-1),
      );
      await group.add(_device('AA:01'));

      await group.disconnectAll();
      await pumpEventQueue();

      // 1 add → 1 emission; disconnectAll → emission of 0; then onDone (-1).
      expect(emissions, [1, 0, -1]);
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
      // gets pushed into the membership list before we tear down.
      final addFuture = group.add(_device('AA:01'));
      await pumpEventQueue();
      expect(group.dumbbells, hasLength(1));

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

      // No orphan: membership cleared, dumbbell disconnected.
      expect(group.dumbbells, isEmpty);
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
}
