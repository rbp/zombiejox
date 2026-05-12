import 'dart:async';

import '../ble/device_ref.dart';
import '../protocol/dumbbell_state.dart';
import '../state/weights.dart';
import 'dumbbell.dart';

/// Immutable view of a [WeightGroup]'s full state at one instant.
///
/// `WeightGroup` recomputes and emits a fresh [GroupSnapshot] on every
/// event that could change one of these fields (member added, member's
/// state stream emitted a new value, connect failed, retry succeeded).
/// Consumers (today, just `ControlScreen`) subscribe once and render as
/// a pure function of the snapshot — no per-screen derivation, no
/// per-dumbbell stream subscriptions, no separate "failed devices"
/// bookkeeping on the view side.
class GroupSnapshot {
  /// Members the group has accepted via [WeightGroup.add] and that have
  /// not (yet) failed to connect. Includes both still-connecting and
  /// ready dumbbells; the renderer reads each one's `isReady` /
  /// `lastState` if it cares about the distinction. Failures leave this
  /// list and reappear in [failed] in the same emission.
  final List<Dumbbell> connected;

  /// Devices whose most recent `add` attempt threw. An entry persists
  /// until the caller calls [WeightGroup.add] again for the same
  /// device — at which point the entry is dropped *atomically* with the
  /// retry's dumbbell landing in [connected]. If the retry also throws,
  /// the entry is replaced with the new error.
  final Map<DeviceRef, Object> failed;

  /// The weight index every state-bearing member agrees on, or null if
  /// no member has reported state yet or if reporters disagree (e.g.
  /// one was nudged via the dock's physical buttons after connect).
  /// Not-yet-state-bearing members are ignored — a single
  /// still-connecting dumbbell never suppresses the indicator for the
  /// rest of the group.
  final int? consensusIndex;

  /// True if any ready member is currently driving its motor (a
  /// `0xD2` with `motorActive` set has been observed).
  final bool anyMoving;

  /// True once any member has finished connecting and reported a state
  /// frame — i.e. `Dumbbell.isReady` is true for at least one member.
  /// Drives the weight grid's enabled / disabled state on the screen.
  final bool anyReady;

  /// Distinct units reported by ready members so far. Empty until the
  /// first `0xD1` reply with a known unit byte arrives.
  final Set<WeightUnit> knownUnits;

  /// How many ready members have reported a known unit byte. Equal to
  /// `knownUnits.length` when every reporter disagrees; larger when
  /// some agree. Fed straight into `UnitAutoMatcher.tick`.
  final int knownUnitCount;

  const GroupSnapshot({
    required this.connected,
    required this.failed,
    required this.consensusIndex,
    required this.anyMoving,
    required this.anyReady,
    required this.knownUnits,
    required this.knownUnitCount,
  });

  static const empty = GroupSnapshot(
    connected: [],
    failed: {},
    consensusIndex: null,
    anyMoving: false,
    anyReady: false,
    knownUnits: <WeightUnit>{},
    knownUnitCount: 0,
  );
}

/// A set of [Dumbbell]s driven as a unit. The default user model: one
/// weight selection applies to every connected dumbbell in parallel.
///
/// The group owns the full per-member state: it subscribes to each
/// member's [Dumbbell.states] stream, dedupes no-op `0xD2` broadcasts,
/// and emits a [GroupSnapshot] whenever something a consumer might
/// render off of changes. Consumers (today, `ControlScreen`) subscribe
/// once to [snapshots] and render as a function of the snapshot — they
/// don't manage their own state subscriptions, don't track failures
/// separately, and don't recompute consensus / motor / unit derivations
/// per build.
class WeightGroup {
  final List<Dumbbell> _dumbbells = [];
  final Map<DeviceRef, Object> _failed = {};
  final Map<Dumbbell, StreamSubscription<DumbbellState>> _stateSubs = {};
  // Per-dumbbell memo of the last state we *processed*. Without this, real
  // dumbbells' ~1 Hz `0xD2` broadcasts (same weightIndex, same motor state)
  // would churn the snapshot stream once per second per member forever.
  final Map<Dumbbell, DumbbellState?> _lastSeen = {};
  final StreamController<GroupSnapshot> _controller =
      StreamController.broadcast();
  GroupSnapshot _last = GroupSnapshot.empty;
  final Dumbbell Function(DeviceRef) _newDumbbell;
  bool _disposed = false;

  /// [newDumbbell] is the factory used by [add] to construct new dumbbells.
  /// Defaults to the real [Dumbbell] implementation; tests pass a factory
  /// that returns a fake.
  WeightGroup({Dumbbell Function(DeviceRef)? newDumbbell})
      : _newDumbbell = newDumbbell ?? Dumbbell.new;

  /// The current snapshot, available synchronously so callers can render
  /// before any stream event arrives (e.g. the first build of a screen).
  GroupSnapshot get lastSnapshot => _last;

  /// Broadcast stream of fresh snapshots. Emits on member add, member
  /// state arrival (deduped against the per-member [_lastSeen]), connect
  /// failure, and [disconnectAll].
  Stream<GroupSnapshot> get snapshots => _controller.stream;

  /// Add a [DeviceRef] to the group and connect to it. The dumbbell is
  /// added to [GroupSnapshot.connected] immediately (so the UI can
  /// render a "connecting" card) and moves to [GroupSnapshot.failed] if
  /// `Dumbbell.connect` throws — both transitions happen via emitted
  /// snapshots, never as a thrown future. Any stale `failed[device]`
  /// entry from a prior failed attempt is cleared atomically with the
  /// retry's dumbbell appearing in `connected`.
  ///
  /// Idempotent against an existing member for the same [DeviceRef]: if
  /// a dumbbell for `device` is already in `connected` (connecting or
  /// ready), the call is a no-op. Prevents a duplicated entry in
  /// `widget.devices` or a rapid-double-tap on retry from spawning two
  /// simultaneous `Dumbbell.connect` attempts to the same peripheral.
  ///
  /// Returns a future that completes when the connect attempt resolves
  /// — successfully or with the new failure already in the snapshot.
  /// The future does NOT surface connect failures; observe the snapshot
  /// instead.
  ///
  /// Throws [StateError] if the group is already disposed — this is a
  /// caller-misuse signal (the retry tap raced against teardown), not a
  /// connect failure.
  Future<void> add(DeviceRef device) async {
    if (_disposed) {
      throw StateError('WeightGroup is disposed');
    }
    // De-dupe against an existing member for the same DeviceRef. The
    // retry UX (FailedDeviceCard's refresh icon) is built around
    // tapping after a failure, by which point the device is no longer
    // in `connected`, so this guard only fires on
    // duplicated-in-widget.devices or rapid-double-tap-on-retry
    // scenarios. Silent no-op rather than throw because that's the
    // ergonomic the caller wants — "an attempt is already in flight,
    // observe the snapshot for the outcome."
    if (_dumbbells.any((d) => d.device == device)) {
      return;
    }
    final db = _newDumbbell(device);
    _dumbbells.add(db);
    // Clear any stale failed entry for this device atomically with the
    // retry's dumbbell landing in `connected`. If we cleared lazily on
    // success, the renderer would briefly see both — old failed card AND
    // new connecting card — for one frame.
    _failed.remove(device);
    _lastSeen[db] = db.lastState;
    // Subscribe BEFORE awaiting connect: a real Dumbbell may not emit
    // states before connect() resolves (the rxSub is wired inside
    // connect()), but the subscription is safe either way and guarantees
    // we don't miss a state that arrives between the success of connect()
    // and our resume point.
    _stateSubs[db] = db.states.listen(_onStateUpdate(db));
    _emit();
    try {
      await db.connect();
      // Success path: nothing to do here. The state subscription is
      // already wired; any state frame that arrives later will emit a
      // fresh snapshot via _onStateUpdate.
    } catch (e) {
      // disconnectAll may have fired during the await; its cleanup
      // already covered this dumbbell. Don't re-populate the failed
      // map after the consumer has navigated away.
      if (_disposed) {
        try {
          await db.disconnect();
        } catch (_) {/* best-effort */}
        return;
      }
      _dumbbells.remove(db);
      _failed[device] = e;
      _lastSeen.remove(db);
      // Emit the failure snapshot synchronously (no `await` first). A
      // racing late state notification on the about-to-be-cancelled
      // subscription is dropped by `_onStateUpdate`'s containsKey
      // guard, so we can let cancel() run in the background. Emitting
      // first matters because consumers' `pumpAndSettle()` returns as
      // soon as the framework is idle, which can happen between the
      // `await db.connect()` rejection and a subsequent
      // `await sub.cancel()` — i.e., the failure snapshot would
      // otherwise land after the test's assertion point.
      _emit();
      unawaited(_stateSubs.remove(db)?.cancel() ?? Future.value());
      // Release the streams + any partially-established BLE handle. The
      // retry UX is built to be tapped repeatedly, so a forgotten
      // disconnect() here would leak one StreamController + one rxSub
      // per failed click.
      try {
        await db.disconnect();
      } catch (_) {/* best-effort */}
    }
  }

  /// Send `0xD6 <index>` to every **ready** member in parallel. Members
  /// that haven't finished connecting yet (`Dumbbell.isReady == false`)
  /// are skipped — calling [Dumbbell.setWeightIndex] on a not-yet-
  /// connected device would throw a `LateInitializationError` on the
  /// underlying TX characteristic. The UI is the primary guard (it
  /// disables weight buttons while no member is ready); this filter is
  /// a defence-in-depth layer so a stray fast tap during the connect
  /// window doesn't crash.
  ///
  /// Errors are not swallowed: the returned future waits for every ready
  /// member's write to complete (success or failure) and then surfaces
  /// the first error if any member failed (standard `Future.wait`
  /// semantics).
  Future<void> setWeightIndex(int index) {
    final ready = [
      for (final d in _dumbbells)
        if (d.isReady) d
    ];
    if (ready.isEmpty) return Future.value();
    return Future.wait([for (final d in ready) d.setWeightIndex(index)]);
  }

  /// Disconnect every member, clear all bookkeeping, and close the
  /// snapshot stream. Best-effort: if one member's `disconnect()`
  /// throws, the rest are still awaited (`eagerError: false`) — teardown
  /// wants completion, not first-error short-circuiting. Idempotent.
  Future<void> disconnectAll() async {
    if (_disposed) return;
    _disposed = true;
    final all = List<Dumbbell>.from(_dumbbells);
    _dumbbells.clear();
    _failed.clear();
    // Clear _lastSeen first so any racing state notification arriving
    // mid-cancel bails on `_onStateUpdate`'s containsKey guard — the
    // `cancel()` calls below are awaited best-effort, and we don't want
    // a late event to slip through during that window and emit a
    // post-teardown snapshot.
    final subs =
        List<StreamSubscription<DumbbellState>>.from(_stateSubs.values);
    _stateSubs.clear();
    _lastSeen.clear();
    for (final s in subs) {
      // Best-effort: a stuck `cancel()` would otherwise stall the entire
      // dispose chain. Each subscription is a local broadcast listener;
      // it can't meaningfully fail.
      try {
        await s.cancel();
      } catch (_) {/* best-effort */}
    }
    _emit();
    await Future.wait(
      all.map((d) => d.disconnect()),
      eagerError: false,
    );
    await _controller.close();
  }

  void Function(DumbbellState) _onStateUpdate(Dumbbell db) {
    return (state) {
      // disconnectAll / catch-block teardown has already removed this
      // dumbbell's bookkeeping. Drop the late state push.
      if (!_lastSeen.containsKey(db)) return;
      if (_lastSeen[db] == state) return;
      _lastSeen[db] = state;
      _emit();
    };
  }

  void _emit() {
    if (_controller.isClosed) return;
    _last = _computeSnapshot();
    _controller.add(_last);
  }

  GroupSnapshot _computeSnapshot() {
    int? consensus;
    var consensusBroken = false;
    var anyMoving = false;
    var anyReady = false;
    final knownUnits = <WeightUnit>{};
    var knownUnitCount = 0;
    // Every derived field gates on `Dumbbell.isReady` rather than just
    // `lastState != null`. `Dumbbell.disconnect()` does not clear
    // `lastState`, so a hypothetical disconnected-but-still-in-
    // `_dumbbells` member would otherwise keep contributing stale data
    // (e.g. a stale `motorActive: true` could spuriously disable the
    // weight grid). In practice both `add()`'s catch and
    // `disconnectAll()` remove members from `_dumbbells` before calling
    // `Dumbbell.disconnect`, but the cheaper invariant is "ready
    // members drive the snapshot, period."
    //
    // The real [Dumbbell] enforces `isReady => lastState != null`, so
    // the second check below is theoretically redundant. We keep it
    // because test fakes have historically used a looser definition
    // (e.g. flipping `isReady` true from inside `connect()` before any
    // state arrives) and a null-deref here would be a needlessly
    // brittle coupling to the contract.
    for (final d in _dumbbells) {
      if (!d.isReady) continue;
      final s = d.lastState;
      if (s == null) continue;
      anyReady = true;
      if (!consensusBroken) {
        if (consensus == null) {
          consensus = s.weightIndex;
        } else if (consensus != s.weightIndex) {
          consensus = null;
          consensusBroken = true;
        }
      }
      if (s.motorActive) anyMoving = true;
      final u = weightUnitFromRawByte(s.unitRaw);
      if (u != null) {
        knownUnits.add(u);
        knownUnitCount++;
      }
    }
    return GroupSnapshot(
      connected: List.unmodifiable(_dumbbells),
      failed: Map.unmodifiable(_failed),
      consensusIndex: consensus,
      anyMoving: anyMoving,
      anyReady: anyReady,
      knownUnits: Set.unmodifiable(knownUnits),
      knownUnitCount: knownUnitCount,
    );
  }
}
