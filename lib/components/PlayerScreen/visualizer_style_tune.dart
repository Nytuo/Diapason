import 'dart:convert';

import 'package:diapason/models/finamp_models.dart';
import 'package:flutter/painting.dart';

/// How a style is coloured.
enum VisualizerColorMode { theme, custom, rainbow }

/// What one [VisualizerStyle] overrides of the global visualizer settings, plus the options only some styles have.
/// A missing key means "use the global value (or the style's default)". Stored as JSON per style name.
class VisualizerStyleTune {
  const VisualizerStyleTune([this._values = const {}]);

  final Map<String, Object> _values;

  static const none = VisualizerStyleTune();

  bool get isEmpty => _values.isEmpty;

  double? _d(String key) => (_values[key] as num?)?.toDouble();

  // Shared with the global settings.
  double? get scale => _d("scale");
  double? get heightFactor => _d("heightFactor");
  double? get smoothing => _d("smoothing");
  double? get strokeWidth => _d("strokeWidth");
  double? get bottomOpacity => _d("bottomOpacity");
  double? get topOpacity => _d("topOpacity");
  bool? get fillEnabled => _values["fillEnabled"] as bool?;
  bool? get useSplines => _values["useSplines"] as bool?;

  // Reactivity: how the bars follow the music.
  /// How fast bars rise (0..1, 1 = instantly) and how fast they fall; null follows the smoothing setting.
  double? get attack => _d("attack");
  double? get release => _d("release");

  /// Frequency tilt, -1 (favour bass) .. 1 (favour treble): music's highs are quieter, so a positive tilt makes the
  /// right side of the spectrum move as much as the left.
  double get tilt => _d("tilt") ?? 0;

  /// Contrast: below 1 lifts quiet parts, above 1 keeps only the loud peaks.
  double get contrast => _d("contrast") ?? 1;

  /// Rescales to the recent loudest level, so quiet tracks move as much as loud ones.
  bool get autoGain => (_values["autoGain"] as bool?) ?? false;

  // Per-style freedom.
  VisualizerColorMode get colorMode =>
      VisualizerColorMode.values.elementAtOrNull((_values["colorMode"] as num?)?.toInt() ?? 0) ??
      VisualizerColorMode.theme;
  Color? get customColor => _values["color"] is num ? Color((_values["color"] as num).toInt()) : null;

  /// Blurred halo behind the shapes, 0..1.
  double get glow => _d("glow") ?? 0;

  /// Bars: their width as a fraction of their slot, and how round their ends are (0..1).
  double get barWidth => _d("barWidth") ?? 0.68;
  double get cornerRadius => _d("cornerRadius") ?? 0.5;

  /// Radial: the inner radius as a fraction of the ring, and how fast it turns.
  double? get innerRadius => _d("innerRadius");
  double get rotation => _d("rotation") ?? 0;

  /// Particles: a size multiplier.
  double get particleSize => _d("particleSize") ?? 1;

  bool has(String key) => _values.containsKey(key);

  VisualizerStyleTune set(String key, Object value) => VisualizerStyleTune({..._values, key: value});

  VisualizerStyleTune clear(String key) => VisualizerStyleTune({..._values}..remove(key));

  Map<String, Object> toJson() => _values;

  static VisualizerStyleTune of(String raw, VisualizerStyle style) {
    if (raw.isEmpty) return none;
    try {
      final entry = (jsonDecode(raw) as Map<String, dynamic>)[style.name];
      if (entry is! Map<String, dynamic>) return none;
      return VisualizerStyleTune({
        for (final e in entry.entries)
          if (e.value is num || e.value is bool) e.key: e.value as Object,
      });
    } catch (_) {
      return none;
    }
  }

  static String update(String raw, VisualizerStyle style, VisualizerStyleTune tune) {
    Map<String, dynamic> all;
    try {
      all = raw.isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      all = {};
    }
    if (tune.isEmpty) {
      all.remove(style.name);
    } else {
      all[style.name] = tune.toJson();
    }
    return all.isEmpty ? "" : jsonEncode(all);
  }
}
