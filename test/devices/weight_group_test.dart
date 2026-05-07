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
  FakeDumbbell(super.device);

  bool connectCalled = false;
  bool failConnect = false;
  Object connectError = StateError('fake connect failure');

  final List<int> setWeightCalls = [];
  bool failSetWeight = false;
  Object setWeightError = StateError('fake set-weight failure');

  bool disconnectCalled = false;

  @override
  Future<void> connect() async {
    connectCalled = true;
    if (failConnect) throw connectError;
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
  });
}
