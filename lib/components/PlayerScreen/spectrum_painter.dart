import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/components/PlayerScreen/visualizer_style_tune.dart';
import 'package:flutter/material.dart';

/// What the spectrum visualizer draws from: the smoothed band levels (0..1), plus a clock and a starfield for the
/// animated styles. Mutated on every tick; the painter repaints through its notifier.
class SpectrumBars {
  Float32List values = Float32List(0);

  /// Seconds the visualizer has been animating.
  double time = 0;

  static const _starCount = 140;
  final _random = Random(7);
  late final List<_Star> stars = List.generate(_starCount, (_) => _Star.random(_random, anyDepth: true));

  /// Mean of the lowest quarter of the bands.
  double get bass {
    final n = values.length;
    if (n == 0) return 0;
    final end = max(1, n ~/ 4);
    var sum = 0.0;
    for (var i = 0; i < end; i++) {
      sum += values[i];
    }
    return sum / end;
  }

  void advance(double dt) {
    time += dt;
    // The stars fly towards the viewer, faster with the bass.
    final speed = 0.08 + bass * 1.6;
    for (final star in stars) {
      star.z -= dt * speed;
      if (star.z <= 0.02) star.reset(_random);
    }
  }
}

class _Star {
  _Star.random(Random random, {bool anyDepth = false}) {
    reset(random, anyDepth: anyDepth);
  }

  double x = 0;
  double y = 0;
  double z = 1;

  void reset(Random random, {bool anyDepth = false}) {
    x = random.nextDouble() * 2 - 1;
    y = random.nextDouble() * 2 - 1;
    z = anyDepth ? 0.05 + random.nextDouble() * 0.95 : 1.0;
  }
}

/// Draws [SpectrumBars] in one of the [VisualizerStyle]s.
class SpectrumPainter extends CustomPainter {
  SpectrumPainter({
    required this.bars,
    required Listenable repaint,
    required this.style,
    required Color accent,
    required this.scale,
    required this.bottomOpacity,
    required this.topOpacity,
    required this.useSplines,
    required this.strokeWidth,
    required this.fillEnabled,
    this.radialInner = 0.45,
    this.tune = VisualizerStyleTune.none,
  }) : accent = tune.colorMode == VisualizerColorMode.custom ? (tune.customColor ?? accent) : accent,
       super(repaint: repaint);

  final SpectrumBars bars;
  final VisualizerStyle style;
  final Color accent;

  /// Per-style options: colour mode, glow, bar shape, ring size and spin, particle size.
  final VisualizerStyleTune tune;
  final double scale;
  final double bottomOpacity;
  final double topOpacity;
  final bool useSplines;
  final double strokeWidth;
  final bool fillEnabled;

  /// For the radial style: the inner radius as a fraction of half the box's shortest side.
  final double radialInner;

  static const _segments = 6;
  static const _headroom = 0.85;

  double _magnitude(int i) => min(bars.values[i] * scale, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final values = bars.values;
    final n = values.length;
    if (n < 2 || size.width <= 0 || size.height <= 0) return;

    var maxBar = 0.0;
    for (var i = 0; i < n; i++) {
      if (values[i] > maxBar) maxBar = values[i];
    }
    if (maxBar < 0.002 && style != VisualizerStyle.particles) return;

    switch (style) {
      case VisualizerStyle.curve:
        _paintCurve(canvas, size);
      case VisualizerStyle.bars:
        _paintBars(canvas, size, mirrored: false);
      case VisualizerStyle.mirroredBars:
        _paintBars(canvas, size, mirrored: true);
      case VisualizerStyle.radial:
        _paintRadial(canvas, size);
      case VisualizerStyle.wave:
        _paintWave(canvas, size);
      case VisualizerStyle.particles:
        _paintStars(canvas, size);
      case VisualizerStyle.blob:
        _paintBlob(canvas, size);
    }
  }

  bool get _rainbow => tune.colorMode == VisualizerColorMode.rainbow;

  /// Hues spread left to right across [rect], at the fill's opacity.
  Shader _rainbowShader(Rect rect, double alpha) => LinearGradient(
    colors: [for (var i = 0; i <= 6; i++) HSLColor.fromAHSL(alpha, i * 60.0, 0.85, 0.6).toColor()],
  ).createShader(rect);

  Paint _fill(Rect rect, {bool centred = false}) {
    if (_rainbow) {
      return Paint()..shader = _rainbowShader(rect, fillEnabled ? max(max(topOpacity, bottomOpacity), 0.5) : 0.9);
    }
    if (!fillEnabled) return Paint()..color = accent.withValues(alpha: max(topOpacity, bottomOpacity));
    final top = accent.withValues(alpha: topOpacity);
    final bottom = accent.withValues(alpha: bottomOpacity);
    return Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: centred ? [top, bottom, top] : [top, bottom],
      ).createShader(rect);
  }

  /// A soft halo under [path], when the style asks for glow.
  void _glow(Canvas canvas, Path path, Size size, {bool stroke = false}) {
    if (tune.glow <= 0) return;
    final paint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + tune.glow * 14)
      ..style = stroke ? PaintingStyle.stroke : PaintingStyle.fill
      ..strokeWidth = max(strokeWidth, 2) * 2;
    if (_rainbow) {
      paint.shader = _rainbowShader(Offset.zero & size, tune.glow * 0.7);
    } else {
      paint.color = accent.withValues(alpha: tune.glow * 0.7);
    }
    canvas.drawPath(path, paint);
  }

  void _paintCurve(Canvas canvas, Size size) {
    final n = bars.values.length;
    final points = List<Offset>.generate(n, (i) {
      return Offset(i / (n - 1) * size.width, size.height - _magnitude(i) * size.height * _headroom);
    }, growable: false);

    final curve = useSplines ? _catmullRom(points) : points;

    final path = Path()..moveTo(curve.first.dx, curve.first.dy);
    for (var i = 1; i < curve.length; i++) {
      path.lineTo(curve[i].dx, curve[i].dy);
    }

    _glow(canvas, path, size, stroke: true);
    if (fillEnabled) {
      final fillPath = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(fillPath, _fill(Offset.zero & size));
    }

    if (strokeWidth > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = accent.withValues(alpha: min(bottomOpacity + 0.15, 1.0))
          ..shader = _rainbow ? _rainbowShader(Offset.zero & size, 1) : null,
      );
    }
  }

  void _paintBars(Canvas canvas, Size size, {required bool mirrored}) {
    final n = bars.values.length;
    final slot = size.width / n;
    final width = max(1.0, slot * tune.barWidth.clamp(0.1, 1.0));
    final radius = Radius.circular(min(width / 2, 12) * tune.cornerRadius.clamp(0.0, 1.0));
    final path = Path();
    final mid = size.height / 2;
    for (var i = 0; i < n; i++) {
      final m = _magnitude(i);
      final x = i * slot + (slot - width) / 2;
      if (mirrored) {
        final h = max(1.0, m * size.height * _headroom);
        path.addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, mid - h / 2, width, h), radius));
      } else {
        final h = max(1.0, m * size.height * _headroom);
        path.addRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(x, size.height - h, width, h), topLeft: radius, topRight: radius),
        );
      }
    }
    _glow(canvas, path, size);
    canvas.drawPath(path, _fill(Offset.zero & size, centred: mirrored));
  }

  void _paintRadial(Canvas canvas, Size size) {
    final n = bars.values.length;
    final centre = size.center(Offset.zero);
    final half = size.shortestSide / 2;
    final inner = half * (tune.innerRadius ?? radialInner);
    final reach = max(4.0, half - inner - 2);
    // Mirrored left and right, lows at the top, so the ring stays balanced.
    final spokes = n * 2;
    final circumference = 2 * pi * inner;
    final width = (circumference / spokes * 0.55).clamp(1.0, 7.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width;
    // One blurred pass for the whole ring (a blur per spoke would cost far more).
    final glowPath = tune.glow > 0 ? Path() : null;
    for (var i = 0; i < n; i++) {
      final m = _magnitude(i);
      final length = max(1.5, m * reach);
      paint.color = _rainbow
          ? HSLColor.fromAHSL(max(0.5, m), i / n * 330, 0.85, 0.6).toColor()
          : Color.lerp(
              accent.withValues(alpha: max(bottomOpacity, 0.35)),
              accent.withValues(alpha: max(topOpacity, 0.9)),
              m,
            )!;

      for (final side in const [1.0, -1.0]) {
        final angle = -pi / 2 + side * pi * (i + 0.5) / n + bars.time * tune.rotation;
        final direction = Offset(cos(angle), sin(angle));
        final from = centre + direction * (inner + 2);
        final to = centre + direction * (inner + 2 + length);
        glowPath
          ?..moveTo(from.dx, from.dy)
          ..lineTo(to.dx, to.dy);
        canvas.drawLine(from, to, paint);
      }
    }
    if (glowPath != null) {
      canvas.drawPath(
        glowPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = width * 1.8
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + tune.glow * 8)
          ..color = accent.withValues(alpha: tune.glow * 0.6),
      );
    }
  }

  /// A line oscillating around the middle: the sum of a few sines whose loudness follows the bands, low bands slow
  /// and wide, high bands quick and narrow. (The spectrum source carries no raw samples, so this is spectrum-shaped
  /// rather than a true oscilloscope trace.)
  void _paintWave(Canvas canvas, Size size) {
    const groups = 8;
    final n = bars.values.length;
    final amps = List<double>.generate(groups, (g) {
      final from = g * n ~/ groups;
      final to = max(from + 1, (g + 1) * n ~/ groups);
      var sum = 0.0;
      for (var i = from; i < to; i++) {
        sum += _magnitude(i);
      }
      return sum / (to - from);
    });
    final total = amps.fold(0.0, (a, b) => a + b);
    if (total <= 0) return;
    final mid = size.height / 2;
    final reach = size.height / 2 * _headroom;
    final t = bars.time;
    final steps = max(32, (size.width / 3).round());
    final path = Path();
    for (var s = 0; s <= steps; s++) {
      final x = s / steps;
      var y = 0.0;
      for (var g = 0; g < groups; g++) {
        final k = g + 1.0;
        y += amps[g] * sin(2 * pi * x * k * 1.5 + t * (1.5 + k * 1.2) + g);
      }
      // Pinned at both ends, loudest in the middle.
      final envelope = sin(pi * x);
      final point = Offset(x * size.width, mid - y / max(total, 1.0) * reach * envelope * 1.6);
      if (s == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    final width = max(strokeWidth, 1.5);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 4
        ..strokeJoin = StrokeJoin.round
        ..color = accent.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = accent.withValues(alpha: min(max(topOpacity, bottomOpacity) + 0.3, 1.0)),
    );
  }

  void _paintStars(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final spread = size.longestSide * 0.5;
    final bass = bars.bass;
    final paint = Paint();
    final glow = Color.lerp(accent, Colors.white, 0.6)!;
    for (final star in bars.stars) {
      final position = centre + Offset(star.x / star.z, star.y / star.z) * spread * 0.35;
      if (position.dx < -4 || position.dy < -4 || position.dx > size.width + 4 || position.dy > size.height + 4) {
        continue;
      }
      final near = (1 - star.z).clamp(0.0, 1.0);
      paint.color = glow.withValues(alpha: (0.15 + near * 0.75).clamp(0.0, 1.0));
      canvas.drawCircle(position, (0.6 + near * (1.8 + bass * 2.5)) * tune.particleSize, paint);
    }
  }

  void _paintBlob(Canvas canvas, Size size) {
    final n = bars.values.length;
    double range(double from, double to) {
      final a = (from * n).floor();
      final b = max(a + 1, (to * n).ceil()).clamp(0, n);
      var sum = 0.0;
      for (var i = a; i < b; i++) {
        sum += _magnitude(i);
      }
      return sum / (b - a);
    }

    final layers = [(range(0, 0.25), 1.2, 0.0), (range(0.25, 0.6), 2.1, 1.7), (range(0.6, 1), 3.4, 3.1)];
    final hsl = HSLColor.fromColor(accent);
    final t = bars.time;
    for (var l = 0; l < layers.length; l++) {
      final (energy, frequency, offset) = layers[l];
      final colour = hsl.withHue((hsl.hue + (l - 1) * 28) % 360).toColor();
      final height = size.height * _headroom * (0.15 + energy * 0.85);
      final path = Path()..moveTo(0, size.height);
      const steps = 48;
      for (var s = 0; s <= steps; s++) {
        final x = s / steps;
        final wobble =
            0.65 +
            0.2 * sin(2 * pi * x * frequency + t * (0.8 + l * 0.5) + offset) +
            0.15 * sin(2 * pi * x * frequency * 2.3 - t * 1.3 + offset);
        path.lineTo(x * size.width, size.height - height * wobble);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              colour.withValues(alpha: max(topOpacity, 0.25)),
              colour.withValues(alpha: bottomOpacity * 0.6),
            ],
          ).createShader(Offset.zero & size),
      );
    }
  }

  List<Offset> _catmullRom(List<Offset> points) {
    final out = <Offset>[];
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[max(i - 1, 0)];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = points[min(i + 2, points.length - 1)];
      for (var s = 0; s < _segments; s++) {
        final t = s / _segments;
        final t2 = t * t;
        final t3 = t2 * t;
        out.add(
          Offset(
            0.5 *
                (2 * p1.dx +
                    (-p0.dx + p2.dx) * t +
                    (2 * p0.dx - 5 * p1.dx + 4 * p2.dx - p3.dx) * t2 +
                    (-p0.dx + 3 * p1.dx - 3 * p2.dx + p3.dx) * t3),
            0.5 *
                (2 * p1.dy +
                    (-p0.dy + p2.dy) * t +
                    (2 * p0.dy - 5 * p1.dy + 4 * p2.dy - p3.dy) * t2 +
                    (-p0.dy + 3 * p1.dy - 3 * p2.dy + p3.dy) * t3),
          ),
        );
      }
    }
    out.add(points.last);
    return out;
  }

  @override
  bool shouldRepaint(SpectrumPainter oldDelegate) =>
      style != oldDelegate.style ||
      accent != oldDelegate.accent ||
      scale != oldDelegate.scale ||
      bottomOpacity != oldDelegate.bottomOpacity ||
      topOpacity != oldDelegate.topOpacity ||
      useSplines != oldDelegate.useSplines ||
      strokeWidth != oldDelegate.strokeWidth ||
      fillEnabled != oldDelegate.fillEnabled ||
      radialInner != oldDelegate.radialInner;
}
