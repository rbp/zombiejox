import 'package:flutter/material.dart';

import '../state/weights.dart';

/// One cell of the weight grid. Shows the weight in [unit], and visually
/// indicates whether it's the currently-selected setting on the connected
/// dumbbell(s).
class WeightButton extends StatelessWidget {
  final int index;
  final WeightUnit unit;
  final bool selected;
  final VoidCallback? onPressed;

  const WeightButton({
    super.key,
    required this.index,
    required this.unit,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final label = formatWeight(index, unit);
    if (selected) {
      return FilledButton(
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return FilledButton.tonal(
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
