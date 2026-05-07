import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'dumbbell.dart';

/// A set of [Dumbbell]s driven as a unit. The default user model: one weight
/// selection applies to every connected dumbbell in parallel.
///
/// The group exposes:
///   - the current member list as [dumbbells]
///   - a stream of member-list changes via [changes]
///   - a [setWeightIndex] that fans out to every member in parallel
///
/// Each member [Dumbbell] keeps its own state stream — UI typically subscribes
/// to [changes] for the membership and to each [Dumbbell.states] for per-device
/// state.
class WeightGroup {
  final List<Dumbbell> _dumbbells = [];
  final StreamController<List<Dumbbell>> _controller =
      StreamController.broadcast();
  final Dumbbell Function(BluetoothDevice) _newDumbbell;
  bool _disposed = false;

  /// [newDumbbell] is the factory used by [add] to construct new dumbbells.
  /// Defaults to the real [Dumbbell] implementation; tests pass a factory
  /// that returns a fake.
  WeightGroup({Dumbbell Function(BluetoothDevice)? newDumbbell})
      : _newDumbbell = newDumbbell ?? Dumbbell.new;

  /// Read-only view of the current members.
  List<Dumbbell> get dumbbells => List.unmodifiable(_dumbbells);

  /// Emits the new member list whenever a dumbbell is added or removed.
  Stream<List<Dumbbell>> get changes => _controller.stream;

  /// Add a [BluetoothDevice] to the group and connect to it. The dumbbell is
  /// added to the membership immediately (so the UI can render a "connecting"
  /// card) and removed if [Dumbbell.connect] throws.
  ///
  /// Throws [StateError] if the group is already disposed, or if it becomes
  /// disposed while `connect()` is in flight — the latter case can happen
  /// when the containing screen pops while a connect is still pending.
  /// In that case the new dumbbell is also disconnected before throwing,
  /// so no orphaned BLE connection is left behind.
  Future<Dumbbell> add(BluetoothDevice device) async {
    if (_disposed) {
      throw StateError('WeightGroup is disposed');
    }
    final db = _newDumbbell(device);
    _dumbbells.add(db);
    _emit();
    try {
      await db.connect();
      if (_disposed) {
        // disconnectAll ran during our await. Make sure this dumbbell is
        // torn down even if disconnectAll's own iteration over a snapshot
        // missed cleaning it up (Dumbbell.disconnect is idempotent so
        // double-disconnect is safe).
        await db.disconnect();
        throw StateError('WeightGroup was disposed during connect');
      }
      return db;
    } catch (e) {
      _dumbbells.remove(db);
      _emit();
      rethrow;
    }
  }

  /// Send `0xD6 <index>` to every **ready** member in parallel. Members that
  /// haven't finished connecting yet (`Dumbbell.isReady == false`) are
  /// skipped — calling [Dumbbell.setWeightIndex] on a not-yet-connected
  /// device would throw a `LateInitializationError` on the underlying TX
  /// characteristic. The UI is the primary guard (it disables weight buttons
  /// while any member is still connecting); this filter is a defence-in-depth
  /// layer so a stray fast tap during the connect window doesn't crash.
  ///
  /// Errors from ready members are not swallowed — the future completes with
  /// the first error if any member fails.
  Future<void> setWeightIndex(int index) {
    final ready = [
      for (final d in _dumbbells)
        if (d.isReady) d
    ];
    if (ready.isEmpty) return Future.value();
    return Future.wait([for (final d in ready) d.setWeightIndex(index)]);
  }

  /// Disconnect all members and close the change stream.
  Future<void> disconnectAll() async {
    if (_disposed) return;
    _disposed = true;
    final all = List<Dumbbell>.from(_dumbbells);
    _dumbbells.clear();
    _emit();
    await Future.wait(all.map((d) => d.disconnect()));
    await _controller.close();
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(List.unmodifiable(_dumbbells));
  }
}
