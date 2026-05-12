import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../devices/dumbbell.dart';
import '../devices/weight_group.dart';
import '../protocol/dumbbell_state.dart';
import '../state/preferences.dart';
import '../state/unit_auto_matcher.dart';
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
  late final WeightGroup _group =
      widget.createWeightGroup?.call() ?? WeightGroup();
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

  late final UnitAutoMatcher _autoMatcher = UnitAutoMatcher(
    preferences: widget.preferences,
    onOutcome: _onAutoMatchOutcome,
  );

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
    final removed = _stateSubs.keys
        .where((d) => !asSet.contains(d))
        .toList(growable: false);
    for (final d in removed) {
      _stateSubs.remove(d)?.cancel();
    }
    // Subscribe to newly-added members. Each subscription keeps a private
    // `lastSeen` so a no-op `0xD2` (same weightIndex, same motor state)
    // doesn't trigger a screen-wide rebuild. Real devices broadcast
    // `0xD2` ~1 Hz; without this filter the whole `_Body` (every card,
    // the 8-button grid) would rebuild once per second per connected
    // dumbbell forever.
    for (final d in current) {
      _stateSubs.putIfAbsent(d, () {
        DumbbellState? lastSeen = d.lastState;
        return d.states.listen((next) {
          if (next == lastSeen) return;
          lastSeen = next;
          if (mounted) setState(() {});
          _maybeFireOnAnyConnected();
          _tickAutoMatcher();
        });
      });
    }
    if (mounted) setState(() {});
    _maybeFireOnAnyConnected();
    _tickAutoMatcher();
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

  /// Compute a [UnitsSnapshot] of the current group state and feed it to
  /// [UnitAutoMatcher.tick]. Hooked from membership changes, every
  /// per-member state-stream emission, and the connect-failure path.
  void _tickAutoMatcher() {
    final knownUnits = <WeightUnit>{};
    var knownUnitCount = 0;
    for (final d in _group.dumbbells) {
      if (!d.isReady) continue;
      final u = weightUnitFromRawByte(d.lastState?.unitRaw);
      if (u == null) continue;
      knownUnits.add(u);
      knownUnitCount++;
    }
    _autoMatcher.tick((
      knownUnits: knownUnits,
      knownUnitCount: knownUnitCount,
      failedCount: _failedDevices.length,
      attemptedCount: widget.devices.length,
    ));
  }

  void _onAutoMatchOutcome(AutoMatchResult result) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result.outcome) {
      case AutoMatchOutcome.matched:
        final label = result.unit == WeightUnit.lbs ? 'lbs' : 'kg';
        messenger.showSnackBar(
          SnackBar(content: Text('Unit set to $label to match your dumbbells.')),
        );
      case AutoMatchOutcome.disagreement:
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
                'Dumbbells are set to different units — pick one in Settings'),
          ),
        );
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
      // A failure changes the "all accounted for" calculus the auto-
      // matcher reads, so tick it again. If at least one member is
      // already ready and the rest are now all failed, the matcher
      // decides immediately instead of waiting on the debounce.
      _tickAutoMatcher();
    }
  }

  @override
  void dispose() {
    // dispose() can't be async, so each Future is explicitly fire-and-forget
    // via `unawaited`. cancel() / disconnectAll() can't meaningfully fail in
    // a way the user can recover from; we just need to release resources.
    _autoMatcher.dispose();
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
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
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
