import 'dart:async';

import '../ble/device_ref.dart';
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
  final Dumbbell Function(DeviceRef) _newDumbbell;
  bool _disposed = false;

  /// [newDumbbell] is the factory used by [add] to construct new dumbbells.
  /// Defaults to the real [Dumbbell] implementation; tests pass a factory
  /// that returns a fake.
  WeightGroup({Dumbbell Function(DeviceRef)? newDumbbell})
      : _newDumbbell = newDumbbell ?? Dumbbell.new;

  /// Read-only view of the current members.
  List<Dumbbell> get dumbbells => List.unmodifiable(_dumbbells);

  /// Emits the new member list whenever a dumbbell is added or removed.
  Stream<List<Dumbbell>> get changes => _controller.stream;

  /// Add a [DeviceRef] to the group and connect to it. The dumbbell is
  /// added to the membership immediately (so the UI can render a "connecting"
  /// card) and removed if [Dumbbell.connect] throws.
  ///
  /// Throws [StateError] if the group is already disposed — guards against a
  /// real leak (a brand-new dumbbell would otherwise connect to BLE with no
  /// owner). The mid-flight case (group disposed while `connect()` is in
  /// flight) is handled by the dumbbell itself: [disconnectAll] captures the
  /// in-flight member in its snapshot and calls `Dumbbell.disconnect`, which
  /// flips the dumbbell's own `_disposed` flag and tears down BLE on the
  /// next `connect()` await checkpoint. Idempotent.
  Future<Dumbbell> add(DeviceRef device) async {
    if (_disposed) {
      throw StateError('WeightGroup is disposed');
    }
    final db = _newDumbbell(device);
    _dumbbells.add(db);
    _emit();
    try {
      await db.connect();
      return db;
    } catch (e) {
      _dumbbells.remove(db);
      _emit();
      // Release the streams + any partially-established BLE handle. The
      // retry UX is built to be tapped repeatedly, so a forgotten
      // `disconnect()` here leaked one StreamController + one rxSub per
      // failed click. `disconnect()` is idempotent and best-effort.
      try {
        await db.disconnect();
      } catch (_) {/* best-effort */}
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
  /// Errors are not swallowed: the returned future waits for every ready
  /// member's write to complete (success or failure) and then surfaces the
  /// first error if any member failed (standard `Future.wait` semantics).
  Future<void> setWeightIndex(int index) {
    final ready = [
      for (final d in _dumbbells)
        if (d.isReady) d
    ];
    if (ready.isEmpty) return Future.value();
    return Future.wait([for (final d in ready) d.setWeightIndex(index)]);
  }

  /// Disconnect all members and close the change stream. Best-effort: if
  /// one member's `disconnect()` throws, the rest are still awaited
  /// (`eagerError: false`) — teardown wants completion, not first-error
  /// short-circuiting.
  Future<void> disconnectAll() async {
    if (_disposed) return;
    _disposed = true;
    final all = List<Dumbbell>.from(_dumbbells);
    _dumbbells.clear();
    _emit();
    await Future.wait(
      all.map((d) => d.disconnect()),
      eagerError: false,
    );
    await _controller.close();
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(List.unmodifiable(_dumbbells));
  }
}
