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
  bool _disposed = false;

  /// Read-only view of the current members.
  List<Dumbbell> get dumbbells => List.unmodifiable(_dumbbells);

  /// Emits the new member list whenever a dumbbell is added or removed.
  Stream<List<Dumbbell>> get changes => _controller.stream;

  /// Add a [BluetoothDevice] to the group and connect to it. The dumbbell is
  /// added to the membership immediately (so the UI can render a "connecting"
  /// card) and removed if [Dumbbell.connect] throws.
  Future<Dumbbell> add(BluetoothDevice device) async {
    final db = Dumbbell(device);
    _dumbbells.add(db);
    _emit();
    try {
      await db.connect();
      return db;
    } catch (e) {
      _dumbbells.remove(db);
      _emit();
      rethrow;
    }
  }

  /// Send `0xD6 <index>` to every connected member in parallel. Errors from
  /// individual members are not swallowed — the future completes with the
  /// first error if any member fails.
  Future<void> setWeightIndex(int index) {
    if (_dumbbells.isEmpty) return Future.value();
    return Future.wait([
      for (final d in _dumbbells) d.setWeightIndex(index),
    ]);
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
