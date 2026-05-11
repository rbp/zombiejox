import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../devices/dumbbell.dart';
import '../devices/weight_group.dart';
import '../protocol/dumbbell_state.dart';
import '../state/preferences.dart';
import '../state/weights.dart';
import '../widgets/dumbbell_card.dart';
import '../widgets/failed_device_card.dart';
import '../widgets/weight_button.dart';
import 'settings_screen.dart';

/// Screen for controlling N connected dumbbells. The membership comes in
/// as [devices]; the screen owns the [WeightGroup] lifecycle.
///
/// Tests can override [createWeightGroup] to inject a [WeightGroup] with a
/// fake-dumbbell factory.
class ControlScreen extends StatefulWidget {
  final List<BluetoothDevice> devices;
  final Preferences preferences;
  final WeightGroup Function()? createWeightGroup;

  /// Fires exactly once, the first time any group member reaches
  /// [Dumbbell.isReady]. Lets the pusher (e.g. [ScanScreen]) commit the
  /// device set to remembered-storage only after a verified successful
  /// connect, rather than speculatively before navigation — so a
  /// failed-to-connect set never poisons the warm-start fast path.
  final VoidCallback? onAnyConnected;

  const ControlScreen({
    super.key,
    required this.devices,
    required this.preferences,
    this.createWeightGroup,
    this.onAnyConnected,
  });

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  late final WeightGroup _group = widget.createWeightGroup?.call() ?? WeightGroup();
  // Devices whose most recent connect attempt threw. Each entry persists
  // until the user taps refresh and the connect either succeeds (entry
  // removed when the device joins the group) or fails again (entry
  // replaced). Rendered in-place — the device's slot in the list stays put;
  // only the card *content* swaps between FailedDeviceCard and DumbbellCard.
  final Map<BluetoothDevice, Object> _failedDevices = {};
  StreamSubscription<List<Dumbbell>>? _changesSub;
  // Per-dumbbell state subscriptions. We trigger setState on every emission
  // so derived values like `_allReady` and the consensus weight refresh
  // promptly — `_group.changes` only fires on membership changes.
  final Map<Dumbbell, StreamSubscription<DumbbellState>> _stateSubs = {};
  bool _onAnyConnectedFired = false;

  // Auto-match-from-dock: once any group member reports a known unit byte,
  // we wait for the rest to be accounted for (ready or failed) — or
  // 1.5s of no-new-state, whichever comes first — and then decide whether
  // to nudge the app's display unit to match the dumbbells'. Sticky per
  // screen instance: re-pushing ControlScreen re-arms it; popping back
  // doesn't.
  Timer? _autoMatchTimer;
  bool _autoMatchDecided = false;
  static const Duration _autoMatchDebounce = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    _changesSub = _group.changes.listen(_onMembership);
    for (final d in widget.devices) {
      _addOne(d);
    }
  }

  void _onMembership(List<Dumbbell> current) {
    final asSet = current.toSet();
    // Drop subscriptions for removed members.
    final removed = _stateSubs.keys.where((d) => !asSet.contains(d)).toList(growable: false);
    for (final d in removed) {
      _stateSubs.remove(d)?.cancel();
    }
    // Subscribe to newly-added members.
    for (final d in current) {
      _stateSubs.putIfAbsent(
        d,
        () => d.states.listen((_) {
          if (mounted) setState(() {});
          _maybeFireOnAnyConnected();
          _maybeArmAutoMatch();
        }),
      );
    }
    if (mounted) setState(() {});
    _maybeFireOnAnyConnected();
    _maybeArmAutoMatch();
  }

  /// Fires [ControlScreen.onAnyConnected] exactly once, the first time any
  /// member reaches [Dumbbell.isReady]. Hooked from both [_onMembership]
  /// (in case a member is already ready when membership changes) and each
  /// per-member state-stream listener (the usual path — `isReady` becomes
  /// true when the first `0xD2` state notification arrives).
  void _maybeFireOnAnyConnected() {
    if (_onAnyConnectedFired) return;
    if (!_group.dumbbells.any((d) => d.isReady)) return;
    _onAnyConnectedFired = true;
    widget.onAnyConnected?.call();
  }

  /// Auto-match the app's display unit to whatever the connected dumbbells
  /// say they're set to (via `0xD1` byte 8 → `DumbbellState.unitRaw` →
  /// [weightUnitFromRawByte]).
  ///
  /// Bails immediately if (a) we've already decided this screen instance,
  /// (b) the user has explicitly picked a unit in Settings, or (c) no
  /// member is ready yet. Otherwise, if every attempted device is
  /// accounted for (ready or failed) we fire the decision right away;
  /// otherwise we debounce 1.5s of no-new-state so a slow-to-connect
  /// mate can still vote.
  void _maybeArmAutoMatch() {
    if (_autoMatchDecided) return;
    if (widget.preferences.unitExplicitlyChosen) {
      _autoMatchDecided = true;
      return;
    }
    final ready = _group.dumbbells.where((d) => d.isReady).toList();
    if (ready.isEmpty) return;
    final allAccountedFor = ready.length + _failedDevices.length >= widget.devices.length;
    _autoMatchTimer?.cancel();
    if (allAccountedFor) {
      unawaited(_decideAutoMatch());
    } else {
      _autoMatchTimer = Timer(_autoMatchDebounce, () {
        unawaited(_decideAutoMatch());
      });
    }
  }

  /// Snapshot the unit byte of every ready member, decide what to do.
  /// Three outcomes: agreement (auto-set the app unit + SnackBar if it
  /// actually changed), disagreement (SnackBar pointing the user to
  /// Settings), or all-unknown (no-op).
  ///
  /// Fire-and-forget — callers `unawaited` this. Any exception (e.g. a
  /// `SharedPreferences` write failure) is swallowed inside; the
  /// decision flag is already set by then, so we can't usefully retry,
  /// and a UX nicety isn't worth crashing the screen over.
  Future<void> _decideAutoMatch() async {
    if (_autoMatchDecided) return;
    _autoMatchDecided = true;
    if (widget.preferences.unitExplicitlyChosen) return;

    try {
      final units = <WeightUnit>{};
      for (final d in _group.dumbbells.where((d) => d.isReady)) {
        final u = weightUnitFromRawByte(d.lastState?.unitRaw);
        if (u != null) units.add(u);
      }

      if (units.length == 1) {
        final u = units.single;
        final changed = await widget.preferences.setUnitIfNotExplicit(u);
        if (!mounted) return;
        if (changed) {
          final label = u == WeightUnit.lbs ? 'lbs' : 'kg';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Unit set to $label to match your dumbbells.')),
          );
        }
      } else if (units.length > 1) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Dumbbells are set to different units — pick one in Settings'),
          ),
        );
      }
      // units.isEmpty: every ready member reported an unknown unit byte.
      // Don't guess — leave the app's display unit at whatever it was.
    } catch (e, st) {
      // A SharedPreferences write failure or a build-context shenanigan
      // shouldn't tear the screen down. Decision is already marked
      // fired, so we won't retry — log and move on.
      debugPrint('auto-match decision failed: $e\n$st');
    }
  }

  Future<void> _addOne(BluetoothDevice device) async {
    // We deliberately don't pre-clear an existing _failedDevices entry: the
    // dumbbell is added to _group synchronously inside _group.add() before
    // the first await, so by the next build dumbbellByDevice already has it
    // and the DumbbellCard preempts the FailedDeviceCard via _cardFor's
    // ordering. Clearing eagerly would briefly leave the slot in neither
    // map and collapse it (the SizedBox.shrink fallback) for one frame.
    try {
      await _group.add(device);
      if (!mounted) return;
      // Connect succeeded — drop any stale failed entry from a prior attempt.
      if (_failedDevices.containsKey(device)) {
        setState(() => _failedDevices.remove(device));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _failedDevices[device] = e);
      // A failure changes the "all accounted for" calculus that
      // _maybeArmAutoMatch reads, so re-check it. If at least one
      // member is already ready and the rest are now all failed, we
      // can decide right away instead of waiting on the debounce.
      _maybeArmAutoMatch();
    }
  }

  @override
  void dispose() {
    // dispose() can't be async, so each Future is explicitly fire-and-forget
    // via `unawaited`. cancel() / disconnectAll() can't meaningfully fail in
    // a way the user can recover from; we just need to release resources.
    _autoMatchTimer?.cancel();
    unawaited(_changesSub?.cancel() ?? Future<void>.value());
    for (final s in _stateSubs.values) {
      unawaited(s.cancel());
    }
    _stateSubs.clear();
    unawaited(_group.disconnectAll());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dumbbells = _group.dumbbells;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ZombieJox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(preferences: widget.preferences),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bluetooth_disabled),
            tooltip: 'Disconnect all',
            onPressed: _disconnectAndPop,
          ),
        ],
      ),
      // Listen to unit so toggling lbs ↔ kg in Settings re-labels every
      // weight button on this screen without a navigation round-trip.
      body: ValueListenableBuilder<WeightUnit>(
        valueListenable: widget.preferences.unit,
        builder: (context, unit, _) => _Body(
          orderedDevices: widget.devices,
          dumbbells: dumbbells,
          unit: unit,
          failedDevices: _failedDevices,
          onSelectIndex: _onSelectIndex,
          onRetry: _addOne,
        ),
      ),
    );
  }

  /// Called when the user taps a weight button. Awaits the fan-out so a
  /// thrown error from any ready-but-failed member surfaces as a SnackBar
  /// instead of becoming an uncaught async exception.
  Future<void> _onSelectIndex(int idx) async {
    try {
      await _group.setWeightIndex(idx);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to set weight: $e')),
      );
    }
  }

  Future<void> _disconnectAndPop() async {
    await _group.disconnectAll();
    if (mounted) Navigator.of(context).pop();
  }
}

class _Body extends StatelessWidget {
  // The devices in their original selection order. Cards render in this
  // order regardless of connection state, so a failed card retrying — which
  // briefly removes it from `failedDevices` and adds it to `dumbbells` —
  // doesn't visually move it past its neighbours.
  final List<BluetoothDevice> orderedDevices;
  final List<Dumbbell> dumbbells;
  final WeightUnit unit;
  final Map<BluetoothDevice, Object> failedDevices;
  final Future<void> Function(int) onSelectIndex;
  final Future<void> Function(BluetoothDevice) onRetry;

  const _Body({
    required this.orderedDevices,
    required this.dumbbells,
    required this.unit,
    required this.failedDevices,
    required this.onSelectIndex,
    required this.onRetry,
  });

  /// The currently-selected weight index, **looking only at ready members**.
  /// Returns null when no member is ready yet, or when ready members
  /// disagree (e.g. one was set manually via the dock buttons after being
  /// connected). Not-ready members are ignored so a single offline dumbbell
  /// doesn't suppress the indicator for the rest of the group.
  int? _consensusIndex() {
    int? agreed;
    for (final d in dumbbells) {
      final s = d.lastState;
      if (s == null) continue;
      if (agreed == null) {
        agreed = s.weightIndex;
      } else if (agreed != s.weightIndex) {
        return null;
      }
    }
    return agreed;
  }

  /// Any ready dumbbell currently moving its motor?
  bool _anyMoving() => dumbbells.any((d) => d.lastState?.motorActive ?? false);

  /// At least one member has finished connecting and is safe to write to.
  /// Set-weight is enabled as soon as this is true — not-ready members are
  /// silently skipped by [WeightGroup.setWeightIndex], so an offline
  /// dumbbell never blocks the rest. Each card still shows its own
  /// "Connecting…" / "Idle" / "Moving…" state.
  bool _anyReady() => dumbbells.any((d) => d.isReady);

  /// Returns the card that belongs in [device]'s slot right now. Distinct
  /// [ValueKey]s per state make [AnimatedSwitcher] treat the connected ↔
  /// failed transitions as a real swap (and cross-fade them) instead of a
  /// no-op rebuild of the same widget.
  Widget _cardFor(
    BluetoothDevice device,
    Map<BluetoothDevice, Dumbbell> dumbbellByDevice,
  ) {
    final dumbbell = dumbbellByDevice[device];
    if (dumbbell != null) {
      return DumbbellCard(
        key: ValueKey('connected-${device.remoteId.str}'),
        dumbbell: dumbbell,
        unit: unit,
      );
    }
    final error = failedDevices[device];
    if (error != null) {
      return FailedDeviceCard(
        key: ValueKey('failed-${device.remoteId.str}'),
        device: device,
        error: error,
        onRetry: () => onRetry(device),
      );
    }
    // Should be unreachable: _addOne keeps the failed entry in place until
    // _group.add either succeeds (dumbbell now in dumbbellByDevice) or fails
    // (failed entry replaced atomically in the same setState as the removal
    // from the group). Kept as a defensive zero-height fallback — a visible
    // placeholder here would itself be the bug.
    return SizedBox.shrink(
      key: ValueKey('pending-${device.remoteId.str}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _consensusIndex();
    final moving = _anyMoving();
    final canPress = _anyReady() && !moving;

    // Cards render in [orderedDevices] order so a device retrying — which
    // briefly leaves [failedDevices] before reappearing in [dumbbells] —
    // doesn't shuffle past its neighbours. AnimatedSwitcher cross-fades
    // the card *content* when a device flips between failed / connecting /
    // connected, while the slot stays put.
    final dumbbellByDevice = {
      for (final d in dumbbells) d.device: d,
    };
    final cards = <Widget>[
      for (final device in orderedDevices)
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
          child: _cardFor(device, dumbbellByDevice),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (orderedDevices.isEmpty)
            const _EmptyHint()
          else ...[
            Expanded(
              flex: 2,
              child: ListView.separated(
                itemCount: cards.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => cards[i],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 3,
              child: GridView.count(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (int i = 0; i < kJaxJoxWeightCount; i++)
                    WeightButton(
                      index: i,
                      unit: unit,
                      selected: selected == i,
                      onPressed: canPress ? () => onSelectIndex(i) : null,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Text('No dumbbells connected.'),
      ),
    );
  }
}
