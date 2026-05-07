import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../devices/dumbbell.dart';
import '../devices/weight_group.dart';
import '../state/preferences.dart';
import '../state/weights.dart';
import '../widgets/dumbbell_card.dart';
import '../widgets/weight_button.dart';

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
  final List<Object> _connectErrors = [];

  @override
  void initState() {
    super.initState();
    for (final d in widget.devices) {
      _addOne(d);
    }
  }

  Future<void> _addOne(BluetoothDevice device) async {
    try {
      await _group.add(device);
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectErrors.add(e));
    }
  }

  @override
  void dispose() {
    _group.disconnectAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.preferences.getUnit();

    return Scaffold(
      appBar: AppBar(
        title: const Text('ZombieJox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth_disabled),
            tooltip: 'Disconnect all',
            onPressed: _disconnectAndPop,
          ),
        ],
      ),
      body: StreamBuilder<List<Dumbbell>>(
        stream: _group.changes,
        initialData: _group.dumbbells,
        builder: (context, snap) {
          final dumbbells = snap.data ?? const <Dumbbell>[];
          return _Body(
            dumbbells: dumbbells,
            unit: unit,
            connectErrors: _connectErrors,
            onSelectIndex: (idx) => _group.setWeightIndex(idx),
          );
        },
      ),
    );
  }

  Future<void> _disconnectAndPop() async {
    await _group.disconnectAll();
    if (mounted) Navigator.of(context).pop();
  }
}

class _Body extends StatelessWidget {
  final List<Dumbbell> dumbbells;
  final WeightUnit unit;
  final List<Object> connectErrors;
  final Future<void> Function(int) onSelectIndex;

  const _Body({
    required this.dumbbells,
    required this.unit,
    required this.connectErrors,
    required this.onSelectIndex,
  });

  /// The currently-selected weight index, if every connected dumbbell agrees.
  /// Returns null when the group is empty, when any device hasn't reported
  /// state yet, or when devices disagree.
  int? _consensusIndex() {
    if (dumbbells.isEmpty) return null;
    int? agreed;
    for (final d in dumbbells) {
      final s = d.lastState;
      if (s == null) return null;
      if (agreed == null) {
        agreed = s.weightIndex;
      } else if (agreed != s.weightIndex) {
        return null;
      }
    }
    return agreed;
  }

  /// Are any connected dumbbells currently moving?
  bool _anyMoving() => dumbbells.any((d) => d.lastState?.motorActive ?? false);

  @override
  Widget build(BuildContext context) {
    final selected = _consensusIndex();
    final moving = _anyMoving();
    final canPress = dumbbells.isNotEmpty && !moving;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (dumbbells.isEmpty && connectErrors.isEmpty)
            const _EmptyHint()
          else ...[
            Expanded(
              flex: 2,
              child: ListView.separated(
                itemCount: dumbbells.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => DumbbellCard(
                  dumbbell: dumbbells[i],
                  unit: unit,
                ),
              ),
            ),
            if (connectErrors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Failed to connect ${connectErrors.length} device(s).',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
