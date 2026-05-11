import 'package:flutter/material.dart';

import '../state/preferences.dart';
import '../state/weights.dart';
import 'about_screen.dart';

/// Settings screen — currently a single lbs/kg toggle and a link to About.
/// Will grow as we add more user-tunable behaviour.
class SettingsScreen extends StatelessWidget {
  final Preferences preferences;

  const SettingsScreen({super.key, required this.preferences});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ValueListenableBuilder<WeightUnit>(
            valueListenable: preferences.unit,
            builder: (context, unit, _) => _UnitTile(
              unit: unit,
              onChanged: preferences.setUnit,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About ZombieJox'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AboutScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnitTile extends StatelessWidget {
  final WeightUnit unit;
  final Future<void> Function(WeightUnit) onChanged;

  const _UnitTile({required this.unit, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Units', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Affects what the app shows. The dumbbell\'s own display is '
            'controlled by the dumbbell itself.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          SegmentedButton<WeightUnit>(
            segments: const [
              ButtonSegment(value: WeightUnit.lbs, label: Text('lbs')),
              ButtonSegment(value: WeightUnit.kg, label: Text('kg')),
            ],
            selected: {unit},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ],
      ),
    );
  }
}
