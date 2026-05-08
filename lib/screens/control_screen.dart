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

  const ControlScreen({
    super.key,
    required this.devices,
    required this.preferences,
    this.createWeightGroup,
  });

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  late final WeightGroup _group =
      widget.createWeightGroup?.call() ?? WeightGroup();
  // Devices whose most recent connect attempt threw. Rendered as
  // FailedDeviceCards at the bottom of the list. Each entry persists until
  // the user taps refresh and the connect either succeeds (entry removed
  // when the device joins the group) or fails again (entry replaced).
  final Map<BluetoothDevice, Object> _failedDevices = {};
  StreamSubscription<List<Dumbbell>>? _changesSub;
  // Per-dumbbell state subscriptions. We trigger setState on every emission
  // so derived values like `_allReady` and the consensus weight refresh
  // promptly — `_group.changes` only fires on membership changes.
  final Map<Dumbbell, StreamSubscription<DumbbellState>> _stateSubs = {};

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
    // Subscribe to newly-added members.
    for (final d in current) {
      _stateSubs.putIfAbsent(
        d,
        () => d.states.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _addOne(BluetoothDevice device) async {
    // Clear any prior failure entry for this device so the failed card
    // disappears while the new attempt is in flight (the device will
    // re-appear in `_group.dumbbells` as a "Connecting…" card via the
    // membership stream).
    if (_failedDevices.containsKey(device)) {
      setState(() => _failedDevices.remove(device));
    }
    try {
      await _group.add(device);
    } catch (e) {
      if (!mounted) return;
      setState(() => _failedDevices[device] = e);
    }
  }

  @override
  void dispose() {
    // dispose() can't be async, so each Future is explicitly fire-and-forget
    // via `unawaited`. cancel() / disconnectAll() can't meaningfully fail in
    // a way the user can recover from; we just need to release resources.
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
  final List<Dumbbell> dumbbells;
  final WeightUnit unit;
  final Map<BluetoothDevice, Object> failedDevices;
  final Future<void> Function(int) onSelectIndex;
  final Future<void> Function(BluetoothDevice) onRetry;

  const _Body({
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

  @override
  Widget build(BuildContext context) {
    final selected = _consensusIndex();
    final moving = _anyMoving();
    final canPress = _anyReady() && !moving;

    // Connecting / connected cards first; failed-to-connect cards at the
    // bottom of the same scrollable list so the user can retry inline.
    final cards = <Widget>[
      for (final d in dumbbells) DumbbellCard(dumbbell: d, unit: unit),
      for (final entry in failedDevices.entries)
        FailedDeviceCard(
          device: entry.key,
          error: entry.value,
          onRetry: () => onRetry(entry.key),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (cards.isEmpty)
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
