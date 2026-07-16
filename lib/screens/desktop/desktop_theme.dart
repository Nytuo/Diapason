import 'package:flutter/material.dart';

class DesktopPalette {
  const DesktopPalette._({
    required this.bg,
    required this.bgSecondary,
    required this.sidebar,
    required this.surface,
    required this.surfaceHover,
    required this.border,
    required this.borderSubtle,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textInverse,
    required this.accent,
    required this.accentMuted,
    required this.danger,
    required this.success,
    required this.brightness,
  });

  final Color bg;
  final Color bgSecondary;
  final Color sidebar;
  final Color surface;
  final Color surfaceHover;
  final Color border;
  final Color borderSubtle;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textInverse;
  final Color accent;
  final Color accentMuted;
  final Color danger;
  final Color success;
  final Brightness brightness;

  factory DesktopPalette.fromScheme(ColorScheme s) {
    return DesktopPalette._(
      bg: s.surface,
      bgSecondary: s.surfaceContainerLow,
      sidebar: s.surfaceContainerLowest,
      surface: s.surfaceContainerHighest,
      surfaceHover: s.surfaceContainerHigh,
      border: s.outlineVariant,
      borderSubtle: s.outlineVariant.withValues(alpha: 0.5),
      textPrimary: s.onSurface,
      textSecondary: s.onSurfaceVariant,
      textTertiary: s.onSurfaceVariant.withValues(alpha: 0.65),
      textInverse: s.onPrimary,
      accent: s.primary,
      accentMuted: s.primary.withValues(alpha: 0.18),
      danger: s.error,
      success: const Color(0xFF50A860),
      brightness: s.brightness,
    );
  }
}

class DesktopThemeScope extends InheritedWidget {
  const DesktopThemeScope({super.key, required this.palette, required super.child});

  final DesktopPalette palette;

  static DesktopPalette of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DesktopThemeScope>();
    assert(scope != null, "No DesktopThemeScope found in context");
    return scope!.palette;
  }

  @override
  bool updateShouldNotify(DesktopThemeScope oldWidget) =>
      palette.accent != oldWidget.palette.accent ||
      palette.bg != oldWidget.palette.bg ||
      palette.brightness != oldWidget.palette.brightness;
}
