import 'package:flutter/material.dart';

/// What is painted behind the desktop window's floating panels
/// (`FinampSettings.desktopAmbientMode`).
enum DesktopAmbientMode {
  /// The plain window colour.
  off,

  /// A soft field of the current album's colours.
  colors,

  /// The current cover, pre-blurred, under a legibility veil.
  cover;

  static DesktopAmbientMode fromName(String name) =>
      DesktopAmbientMode.values.firstWhere((m) => m.name == name, orElse: () => DesktopAmbientMode.cover);
}

/// Sizes of the desktop design system: one place for the radii, gaps and
/// paddings every desktop page uses, so pages added later line up with the
/// shell without copying numbers.
abstract final class DesktopMetrics {
  /// Gap between the window edge and the floating panels, and between panels.
  static const double windowGap = 8;
  static const double sidebarWidth = 240;
  static const double lyricsWidth = 360;
  static const double headerHeight = 60;
  static const double playerBarHeight = 132;

  // Radii.
  static const double radiusPanel = 12;
  static const double radiusPlayer = 14;
  static const double radiusCard = 10;
  static const double radiusControl = 8;
  static const double radiusItem = 7;
  static const double radiusArtSmall = 6;

  /// Inner padding of a page inside the content panel.
  static const double pagePadding = 24;

  /// Vertical space between two sections of a page.
  static const double sectionGap = 32;

  /// Space between a section header and its content.
  static const double sectionHeaderGap = 12;

  /// Space between items of a horizontal shelf.
  static const double shelfGap = 16;
}

class DesktopPalette {
  const DesktopPalette._({
    required this.window,
    required this.chrome,
    required this.panel,
    required this.panelBorder,
    required this.veil,
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
    required this.ambient,
    required this.reduceEffects,
  });

  /// The colour of the window behind every panel (under the ambient layer).
  final Color window;

  /// Fill of the translucent chrome: sidebar, player bar, side panels.
  final Color chrome;

  /// Fill of the content panel the pages draw in.
  final Color panel;

  /// The hairline around floating panels and cards ("frost").
  final Color panelBorder;

  /// Legibility veil over the ambient background.
  final Color veil;

  /// What a page paints as its own background. Transparent while the ambient
  /// background is on, so the content panel's translucent fill shows through.
  final Color bg;

  /// Opaque raised background: dialogs, popovers, the command palette.
  final Color bgSecondary;

  /// Same as [chrome]; kept for older call sites.
  final Color sidebar;

  /// Fill of controls and cards inside a panel (search field, chips, tiles).
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

  /// Whether the ambient background is painting behind the panels.
  final bool ambient;

  /// The "reduce effects" setting: skip animations and costly decoration.
  final bool reduceEffects;

  bool get isDark => brightness == Brightness.dark;

  /// Duration for decorative transitions, zero when effects are reduced.
  Duration motion(Duration d) => reduceEffects ? Duration.zero : d;

  factory DesktopPalette.fromScheme(ColorScheme s, {bool ambient = false, bool reduceEffects = false}) {
    final dark = s.brightness == Brightness.dark;
    final ink = dark ? Colors.white : Colors.black;
    final opaquePanel = dark ? s.surface : s.surfaceContainerLowest;
    final opaqueChrome = dark ? s.surfaceContainerLow : s.surfaceContainerLow;
    return DesktopPalette._(
      window: ambient ? s.surface : (dark ? s.surfaceContainerLowest : s.surfaceContainerHigh),
      chrome: ambient ? opaqueChrome.withValues(alpha: dark ? 0.50 : 0.55) : opaqueChrome,
      panel: ambient ? opaquePanel.withValues(alpha: dark ? 0.30 : 0.45) : opaquePanel,
      panelBorder: ink.withValues(alpha: dark ? 0.09 : 0.07),
      veil: dark ? Colors.black.withValues(alpha: 0.35) : s.surface.withValues(alpha: 0.55),
      bg: ambient ? Colors.transparent : opaquePanel,
      bgSecondary: s.surfaceContainerLow,
      sidebar: ambient ? opaqueChrome.withValues(alpha: dark ? 0.50 : 0.55) : opaqueChrome,
      surface: ambient ? ink.withValues(alpha: dark ? 0.07 : 0.05) : s.surfaceContainerHighest,
      surfaceHover: ambient ? ink.withValues(alpha: dark ? 0.11 : 0.08) : s.surfaceContainerHigh,
      border: ambient ? ink.withValues(alpha: dark ? 0.16 : 0.12) : s.outlineVariant,
      borderSubtle: ambient ? ink.withValues(alpha: dark ? 0.08 : 0.06) : s.outlineVariant.withValues(alpha: 0.5),
      textPrimary: s.onSurface,
      textSecondary: s.onSurfaceVariant,
      textTertiary: s.onSurfaceVariant.withValues(alpha: 0.65),
      textInverse: s.onPrimary,
      accent: s.primary,
      accentMuted: s.primary.withValues(alpha: 0.18),
      danger: s.error,
      success: const Color(0xFF50A860),
      brightness: s.brightness,
      ambient: ambient,
      reduceEffects: reduceEffects,
    );
  }

  // Typography: the hierarchy every desktop page uses.

  /// Page title (artist name, "Home").
  TextStyle get display =>
      TextStyle(color: textPrimary, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.15);

  /// Title of the header bar and of large cards.
  TextStyle get title =>
      TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3, height: 1.2);

  /// Section header ("Recently added albums").
  TextStyle get section =>
      TextStyle(color: textPrimary, fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.3, height: 1.2);

  /// Primary line of a list row or card.
  TextStyle get body => TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w500, height: 1.3);

  /// Secondary line of a list row or card.
  TextStyle get caption => TextStyle(color: textSecondary, fontSize: 12, height: 1.3);

  /// Small capitals above groups ("PLAYLISTS", "JUMP TO").
  TextStyle get overline =>
      TextStyle(color: textTertiary, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.1);

  /// A flat app bar in this palette, for mobile screens framed inside the
  /// content panel (`DesktopPageFrame`): no fill of its own over the ambient
  /// background, the [title] type, a hairline underneath.
  AppBarThemeData appBarTheme([AppBarThemeData base = const AppBarThemeData()]) => base.copyWith(
    backgroundColor: bg,
    surfaceTintColor: Colors.transparent,
    foregroundColor: textPrimary,
    elevation: 0,
    scrolledUnderElevation: 0,
    centerTitle: false,
    toolbarHeight: 52,
    titleTextStyle: title,
    iconTheme: IconThemeData(color: textSecondary, size: 20),
    actionsIconTheme: IconThemeData(color: textSecondary, size: 20),
    shape: Border(bottom: BorderSide(color: borderSubtle)),
  );

  /// The theme a page inside the content panel builds on: transparent
  /// scaffolds over the ambient background and [appBarTheme].
  ThemeData pageTheme(ThemeData base) =>
      base.copyWith(scaffoldBackgroundColor: bg, appBarTheme: appBarTheme(base.appBarTheme));

  @override
  bool operator ==(Object other) =>
      other is DesktopPalette &&
      other.accent == accent &&
      other.window == window &&
      other.panel == panel &&
      other.chrome == chrome &&
      other.textPrimary == textPrimary &&
      other.brightness == brightness &&
      other.ambient == ambient &&
      other.reduceEffects == reduceEffects;

  @override
  int get hashCode => Object.hash(accent, window, panel, chrome, textPrimary, brightness, ambient, reduceEffects);
}

class DesktopThemeScope extends InheritedWidget {
  const DesktopThemeScope({super.key, required this.palette, required super.child});

  final DesktopPalette palette;

  static DesktopPalette of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DesktopThemeScope>();
    assert(scope != null, "No DesktopThemeScope found in context");
    return scope!.palette;
  }

  /// The palette when inside the desktop shell, else null.
  static DesktopPalette? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopThemeScope>()?.palette;

  @override
  bool updateShouldNotify(DesktopThemeScope oldWidget) => palette != oldWidget.palette;
}
