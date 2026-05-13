import 'package:flutter/material.dart';

/// App-wide theme. Dark-first: this is a workout app used in low-light
/// gyms / home gyms, and the screen is often glanced at, not read. A dark
/// theme also gives the weight-grid tiles a higher-contrast container fill
/// for the selected state.
class AppTheme {
  /// Deep aubergine seed. Picked to feel "iron / equipment" rather than
  /// "consumer fitness app" — saturated enough to read as a brand colour,
  /// dark enough that the M3 algorithm derives a readable on-surface scheme.
  static const Color seedColor = Color(0xFF4A1942);

  static ThemeData darkTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
    );
  }
}
