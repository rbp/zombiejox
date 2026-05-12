import 'package:flutter/material.dart';

import '../state/weights.dart';

/// One cell of the weight grid. Shows the weight in [unit], and visually
/// indicates whether it's the currently-selected setting on the connected
/// dumbbell(s).
///
/// Visual contract (PR 1 of the v1 design):
/// - Fixed rectangular tile, slightly rounded corners, same dimensions
///   across all 8 cells. The grid sizes the cell; this widget fills it.
/// - Container fill from the active [ColorScheme]: selected uses the
///   primary container, unselected uses the surface variant. No
///   FilledButton variant swap (M3 `FilledButton` vs `FilledButton.tonal`
///   resolve to indistinguishable tiles in our scheme).
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
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;

    final Color fill;
    final Color textColor;
    if (selected) {
      fill = enabled
          ? scheme.primary
          : scheme.primary.withValues(alpha: 0.38);
      textColor = enabled
          ? scheme.onPrimary
          : scheme.onPrimary.withValues(alpha: 0.6);
    } else {
      fill = enabled
          ? scheme.surfaceContainerHighest
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5);
      textColor = enabled
          ? scheme.onSurface
          : scheme.onSurface.withValues(alpha: 0.38);
    }

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    // Workout app — the user's eyes are often on the equipment, not the
    // screen. Spell out the selected state for VoiceOver / TalkBack so
    // a tap doesn't feel ambiguous. excludeSemantics drops the inner
    // InkWell semantics (including its tap action), so we explicitly
    // forward onTap here — otherwise assistive tech can't activate the
    // control even when onPressed is non-null.
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: selected ? '$label, currently set' : label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Material(
        color: fill,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(4),
              // FittedBox + scaleDown so the label shrinks to fit inside
              // the tile at large text scales (a11y TextScaler up to ~2×
              // and beyond) rather than clipping. softWrap:false keeps
              // labels like "22.7 kg" on one line.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  softWrap: false,
                  maxLines: 1,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
