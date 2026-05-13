import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zombiejox/ble/ble_connection_state.dart';
import 'package:zombiejox/ble/ble_transport.dart';
import 'package:zombiejox/ble/device_ref.dart';
import 'package:zombiejox/devices/dumbbell.dart';
import 'package:zombiejox/protocol/frame.dart';
import 'package:zombiejox/protocol/opcodes.dart';

/// In-memory [BleTransport] used by the proxy-replay test. Lets the
/// test push connection-state events into a Dumbbell at controlled
/// times.
class _FakeTransport implements BleTransport {
  _FakeTransport(this.device);

  @override
  final DeviceRef device;

  final _conn = StreamController<BleConnectionState>.broadcast();
  final _rx = StreamController<List<int>>.broadcast();

  /// Records every TX write — drives the §2g `refresh()` opcode test.
  final List<List<int>> writes = [];

  @override
  Stream<BleConnectionState> get connectionState => _conn.stream;

  @override
  Stream<List<int>> get rxStream => _rx.stream;

  void emitConn(BleConnectionState s) => _conn.add(s);

  /// Push bytes through the RX channel as if the firmware had just
  /// emitted them — drives `Dumbbell._onBytes` from the test side.
  void emitRx(List<int> bytes) => _rx.add(bytes);

  @override
  Future<void> connect() async {/* no-op */}

  @override
  Future<void> writeTx(List<int> bytes) async {
    writes.add(List.unmodifiable(bytes));
  }

  @override
  Future<int?> readBatteryLevel() async => null;

  @override
  Future<void> disconnect() async {
    if (!_conn.isClosed) await _conn.close();
    if (!_rx.isClosed) await _rx.close();
  }
}

void main() {
  group('setWeightIndex bounds', () {
    // The check fires before any BLE I/O, so a freshly constructed
    // Dumbbell that has not connected is safe to probe directly.
    test('throws RangeError for negative indices', () async {
      final d = Dumbbell(const DeviceRef(id: 'AA:01'));
      expect(() => d.setWeightIndex(-1), throwsRangeError);
    });

    test('throws RangeError for indices >= 8', () async {
      final d = Dumbbell(const DeviceRef(id: 'AA:01'));
      expect(() => d.setWeightIndex(8), throwsRangeError);
      expect(() => d.setWeightIndex(99), throwsRangeError);
    });

    test('the boundaries 0 and 7 are NOT a RangeError', () {
      // On an unconnected Dumbbell, in-range indices still throw — but
      // they throw `StateError` from the BLE layer ("not connected"),
      // *not* `RangeError`. That distinction is what callers will
      // disambiguate on, so pin it down.
      final d = Dumbbell(const DeviceRef(id: 'AA:01'));
      expect(() => d.setWeightIndex(0), isNot(throwsRangeError));
      expect(() => d.setWeightIndex(7), isNot(throwsRangeError));
    });
  });

  group('connectionState late-subscribe replay (§2a Copilot follow-up)', () {
    test(
        'a second subscriber that joins after the first event has '
        'been emitted still sees the latest state', () async {
      // The bug Copilot flagged: WeightGroup subscribes first (in
      // `add()`), the underlying transport replays the current state
      // to that subscriber via the forwarder, and a DumbbellCard that
      // later builds + subscribes through the broadcast proxy would
      // see nothing until the *next* transition — leaving the card
      // stuck on "Connecting…" for an already-connected dumbbell.
      late _FakeTransport transport;
      final d = Dumbbell(
        const DeviceRef(id: 'AA:01'),
        transportFactory: (ref) => transport = _FakeTransport(ref),
      );

      // First subscriber attaches (mirrors WeightGroup's supervisor).
      final firstEvents = <BleConnectionState>[];
      final firstSub = d.connectionState.listen(firstEvents.add);

      // Transport emits `connected`; first subscriber sees it.
      transport.emitConn(BleConnectionState.connected);
      await pumpEventQueue();
      expect(firstEvents, [BleConnectionState.connected]);

      // SECOND subscriber attaches AFTER the event was already emitted.
      // It must still see the current state — this is the fix.
      final lateEvents = <BleConnectionState>[];
      final lateSub = d.connectionState.listen(lateEvents.add);
      await pumpEventQueue();

      expect(lateEvents, [BleConnectionState.connected],
          reason: 'late subscriber must receive the cached current state');

      await firstSub.cancel();
      await lateSub.cancel();
      await d.disconnect();
    });

    test(
        'every subsequent transport event is fanned out to all live '
        'subscribers', () async {
      late _FakeTransport transport;
      final d = Dumbbell(
        const DeviceRef(id: 'AA:01'),
        transportFactory: (ref) => transport = _FakeTransport(ref),
      );

      final eventsA = <BleConnectionState>[];
      final eventsB = <BleConnectionState>[];
      final subA = d.connectionState.listen(eventsA.add);
      final subB = d.connectionState.listen(eventsB.add);

      transport.emitConn(BleConnectionState.connected);
      transport.emitConn(BleConnectionState.disconnected);
      await pumpEventQueue();

      expect(
          eventsA,
          [
            BleConnectionState.connected,
            BleConnectionState.disconnected,
          ],
          reason: 'first subscriber receives the full sequence');
      expect(
          eventsB,
          [
            BleConnectionState.connected,
            BleConnectionState.disconnected,
          ],
          reason: 'second subscriber receives the full sequence too');

      await subA.cancel();
      await subB.cancel();
      await d.disconnect();
    });

    test('subscribing after disconnect closes the stream cleanly', () async {
      late _FakeTransport transport;
      final d = Dumbbell(
        const DeviceRef(id: 'AA:01'),
        transportFactory: (ref) => transport = _FakeTransport(ref),
      );
      final sub1 = d.connectionState.listen((_) {});
      transport.emitConn(BleConnectionState.connected);
      await pumpEventQueue();

      await d.disconnect();

      // Post-disconnect subscriber should observe an immediate onDone.
      var done = false;
      d.connectionState.listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();
      expect(done, isTrue,
          reason: 'post-disconnect subscriber must not hang forever');

      await sub1.cancel();
    });
  });

  group('refresh (§2g pull-to-refresh)', () {
    // A minimal `0xD1` reply built through the live frame builder so the
    // test stays decoupled from the byte layout — `applyFrame` parses
    // exactly six payload bytes and we hand it 0s for each. Drops
    // through to `Dumbbell._onBytes` → state emit, which flips
    // `isReady` true so `refresh()` doesn't short-circuit.
    final readyReply = buildFrame(Opcodes.queryStatus, [0, 0, 0, 0, 0, 0]);

    test('on a ready dumbbell: writes a queryStatus (0xD1) frame to TX',
        () async {
      late _FakeTransport transport;
      final d = Dumbbell(
        const DeviceRef(id: 'AA:01'),
        transportFactory: (ref) => transport = _FakeTransport(ref),
      );
      await d.connect();
      // `connect()` itself fires a queryStatus as part of the handshake.
      // Drop the setup writes so the assertion below only sees the
      // refresh write.
      transport.writes.clear();
      transport.emitRx(readyReply);
      await pumpEventQueue();
      expect(d.isReady, isTrue, reason: 'state frame arrived ⇒ ready');

      await d.refresh();

      expect(transport.writes, hasLength(1));
      final parsed = parseFrame(transport.writes.single);
      expect(parsed, isNotNull,
          reason: 'refresh write must be a well-formed JaxJox frame');
      expect(parsed!.opcode, Opcodes.queryStatus,
          reason: 'refresh fires the 0xD1 queryStatus opcode');

      await d.disconnect();
    });

    test('on a not-yet-ready dumbbell: no-op (no TX write)', () async {
      late _FakeTransport transport;
      final d = Dumbbell(
        const DeviceRef(id: 'AA:01'),
        transportFactory: (ref) => transport = _FakeTransport(ref),
      );
      // Skip connect entirely — isReady is false from construction.
      transport.writes.clear();

      await d.refresh();

      expect(transport.writes, isEmpty,
          reason: 'no write when isReady is false');
    });

    test('on a disposed dumbbell: no-op', () async {
      late _FakeTransport transport;
      final d = Dumbbell(
        const DeviceRef(id: 'AA:01'),
        transportFactory: (ref) => transport = _FakeTransport(ref),
      );
      await d.connect();
      transport.emitRx(readyReply);
      await pumpEventQueue();
      await d.disconnect();
      transport.writes.clear();

      await d.refresh();

      expect(transport.writes, isEmpty,
          reason: 'disposed dumbbells must not write');
    });
  });
}
