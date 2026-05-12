import 'dart:async';

import 'package:flutter/material.dart';

import '../ble/device_ref.dart';
import '../devices/dumbbell.dart';
import '../devices/weight_group.dart';
import '../state/preferences.dart';
import '../state/unit_auto_matcher.dart';
import '../state/weights.dart';
import '../widgets/dumbbell_card.dart';
import '../widgets/failed_device_card.dart';
import '../widgets/weight_button.dart';
import 'settings_screen.dart';

/// Screen for controlling N connected dumbbells. The membership comes in
/// as [devices]; the screen owns the [WeightGroup] lifecycle and is a
/// pure projection of [WeightGroup.snapshots] — no per-dumbbell stream
/// subscriptions, no failed-devices bookkeeping, no consensus / motor /
/// unit derivations of its own.
///
/// Tests can override [createWeightGroup] to inject a [WeightGroup] with
/// a fake-dumbbell factory.
class ControlScreen extends StatefulWidget {
  final List<DeviceRef> devices;
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
  StreamSubscription<GroupSnapshot>? _snapshotSub;
  GroupSnapshot _snapshot = GroupSnapshot.empty;
  bool _onAnyConnectedFired = false;

  late final UnitAutoMatcher _autoMatcher = UnitAutoMatcher(
    preferences: widget.preferences,
    onOutcome: _onAutoMatchOutcome,
  );

  @override
  void initState() {
    super.initState();
    _snapshot = _group.lastSnapshot;
    _snapshotSub = _group.snapshots.listen(_onSnapshot);
    for (final d in widget.devices) {
      _addOne(d);
    }
  }

  void _onSnapshot(GroupSnapshot snapshot) {
    if (!mounted) return;
    setState(() => _snapshot = snapshot);
    _maybeFireOnAnyConnected();
    _tickAutoMatcher();
  }

  /// Fires [ControlScreen.onAnyConnected] exactly once, the first time
  /// any member reaches [Dumbbell.isReady]. Reads off the snapshot so
  /// it sees every transition `WeightGroup` emits — membership add,
  /// state-frame arrival, retry success.
  void _maybeFireOnAnyConnected() {
    if (_onAnyConnectedFired) return;
    if (!_snapshot.anyReady) return;
    _onAnyConnectedFired = true;
    widget.onAnyConnected?.call();
  }

  /// Feed the matcher the current snapshot. `failedCount` comes from
  /// the snapshot's failed map; `attemptedCount` is the original
  /// selection (screen-level info the group can't know about).
  void _tickAutoMatcher() {
    _autoMatcher.tick((
      knownUnits: _snapshot.knownUnits,
      knownUnitCount: _snapshot.knownUnitCount,
      failedCount: _snapshot.failed.length,
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
          SnackBar(
              content: Text('Unit set to $label to match your dumbbells.')),
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

  Future<void> _addOne(DeviceRef device) async {
    // WeightGroup owns the failure-as-snapshot pipeline; the screen just
    // asks for an attempt and reacts to the next emitted snapshot. The
    // only thing add() can throw is StateError-after-disposal — caused
    // by a retry tap racing the dispose-all flow during teardown; we
    // can safely ignore it because the screen is on its way out anyway.
    try {
      await _group.add(device);
    } on StateError {
      // Group disposed mid-flight; nothing to recover.
    }
  }

  @override
  void dispose() {
    // dispose() can't be async, so each Future is explicitly fire-and-
    // forget via `unawaited`. cancel() / disconnectAll() can't
    // meaningfully fail in a way the user can recover from; we just
    // need to release resources.
    _autoMatcher.dispose();
    unawaited(_snapshotSub?.cancel() ?? Future<void>.value());
    unawaited(_group.disconnectAll());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          snapshot: _snapshot,
          unit: unit,
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
  // order regardless of connection state, so a failed card retrying —
  // which moves the device from `snapshot.failed` back to
  // `snapshot.connected` — doesn't visually move it past its
  // neighbours.
  final List<DeviceRef> orderedDevices;
  final GroupSnapshot snapshot;
  final WeightUnit unit;
  final Future<void> Function(int) onSelectIndex;
  final Future<void> Function(DeviceRef) onRetry;

  const _Body({
    required this.orderedDevices,
    required this.snapshot,
    required this.unit,
    required this.onSelectIndex,
    required this.onRetry,
  });

  /// Returns the card that belongs in [device]'s slot right now.
  /// Distinct [ValueKey]s per state make [AnimatedSwitcher] treat the
  /// connected ↔ failed transitions as a real swap (and cross-fade
  /// them) instead of a no-op rebuild of the same widget.
  Widget _cardFor(
    DeviceRef device,
    Map<DeviceRef, Dumbbell> dumbbellByDevice,
  ) {
    final dumbbell = dumbbellByDevice[device];
    if (dumbbell != null) {
      return DumbbellCard(
        key: ValueKey('connected-${device.id}'),
        dumbbell: dumbbell,
        unit: unit,
      );
    }
    final error = snapshot.failed[device];
    if (error != null) {
      return FailedDeviceCard(
        key: ValueKey('failed-${device.id}'),
        device: device,
        error: error,
        onRetry: () => onRetry(device),
      );
    }
    // Unreachable in practice: WeightGroup.add atomically drops the
    // failed entry the moment the retry's dumbbell lands in `connected`,
    // so the slot never falls into the "neither map" pocket. Kept as a
    // defensive zero-height fallback — a visible placeholder here would
    // itself be the bug.
    return SizedBox.shrink(
      key: ValueKey('pending-${device.id}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = snapshot.consensusIndex;
    final canPress = snapshot.anyReady && !snapshot.anyMoving;

    // Cards render in [orderedDevices] order so a device retrying —
    // which briefly leaves snapshot.failed before reappearing in
    // snapshot.connected — doesn't shuffle past its neighbours.
    // AnimatedSwitcher cross-fades the card *content* when a device
    // flips between failed / connecting / connected, while the slot
    // stays put.
    final dumbbellByDevice = {
      for (final d in snapshot.connected) d.device: d,
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
