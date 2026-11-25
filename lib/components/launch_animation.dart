import 'package:diapason/utils/platform.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Plays a short logo animation over [child] the first time it is built after a cold start, on phones and tablets.
///
/// It picks up exactly where the native splash screen stops (same background colour, same tile size, centred), so
/// the hand-off is seamless: the tuning fork rings, sound waves ripple out, then the tile blooms away to reveal the
/// app. [child] is always kept at the same position in the tree, so nothing underneath is rebuilt or loses state when
/// the animation ends.
class LaunchAnimationOverlay extends StatefulWidget {
  const LaunchAnimationOverlay({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// Set false on form factors that should skip the animation (TV, watch, iPod mode...).
  final bool enabled;

  /// Only the first build per process animates; later rebuilds of the splash route are silent.
  static bool _played = false;

  @visibleForTesting
  static void resetForTest() => _played = false;

  @override
  State<LaunchAnimationOverlay> createState() => _LaunchAnimationOverlayState();
}

class _LaunchAnimationOverlayState extends State<LaunchAnimationOverlay> with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 2000);

  late final AnimationController _controller;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _duration);
    _active = widget.enabled && !LaunchAnimationOverlay._played && (Platform.isIOS || Platform.isAndroid);
    LaunchAnimationOverlay._played = true;
    if (_active) {
      _controller.forward().whenComplete(() {
        if (mounted) setState(() => _active = false);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect "reduce motion": skip straight to the app.
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final showOverlay = _active && !reduceMotion;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (showOverlay)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: LaunchLogoPainter(
                    progress: _controller.value,
                    background: MediaQuery.platformBrightnessOf(context) == Brightness.dark
                        ? const Color(0xFF101315)
                        : const Color(0xFFFCFDFE),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Draws the Diapason logo (a tuning fork with sound waves on a rounded tile) in vector form, driven by [progress]
/// from 0 to 1. Geometry follows `assets/icon/icon.svg`, a 1024 unit square.
class LaunchLogoPainter extends CustomPainter {
  LaunchLogoPainter({required this.progress, required this.background});

  final double progress;
  final Color background;

  // Timeline, as fractions of the whole animation.
  static const _ring = Interval(0.00, 0.55);
  static const _hold = 0.55;
  static const _exit = Interval(0.62, 1.00, curve: Curves.easeInOutCubic);

  static final _fork = Path()
    ..moveTo(392, 250)
    ..lineTo(392, 520)
    ..arcToPoint(const Offset(632, 520), radius: const Radius.circular(120), clockwise: false)
    ..lineTo(632, 250)
    ..moveTo(512, 640)
    ..lineTo(512, 770);

  static final _leftArc = Path()
    ..moveTo(290, 360)
    ..quadraticBezierTo(230, 470, 290, 580);
  static final _rightArc = Path()
    ..moveTo(734, 360)
    ..quadraticBezierTo(794, 470, 734, 580);

  static Paint _arcPaint(double alpha) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 46
    ..strokeCap = StrokeCap.round
    ..color = const Color(0xFF7FD6FF).withValues(alpha: alpha);

  @override
  void paint(Canvas canvas, Size size) {
    final exit = _exit.transform(progress);

    // Background: same colour as the native splash, dissolving at the end.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = background.withValues(alpha: 1 - Curves.easeIn.transform(exit)),
    );

    // Tile: starts at the native splash size (a 128pt box) and blooms outward while fading.
    final base = 128.0;
    final bloom = 1 + exit * 9;
    final tileSize = base * bloom;
    final tileOpacity = (1 - Curves.easeIn.transform(math.min(1, exit * 1.15))).clamp(0.0, 1.0);
    final center = size.center(Offset.zero);

    // A gentle pulse as the fork is struck (1.0 at both ends so the hand-off from the native splash is exact).
    final settle = 1 + 0.05 * math.sin(Interval(0.0, 0.3).transform(progress) * math.pi);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(tileSize / 1024 * settle);
    canvas.translate(-512, -512);

    final tile = RRect.fromRectAndRadius(const Rect.fromLTWH(100, 100, 824, 824), const Radius.circular(185));
    canvas.save();
    canvas.clipRRect(tile);
    canvas.drawRect(
      const Rect.fromLTWH(100, 100, 824, 824),
      Paint()
        ..shader = ui.Gradient.linear(const Offset(0, 100), const Offset(0, 924), [
          const Color(0xFF2A7FEA).withValues(alpha: tileOpacity),
          const Color(0xFF0A3A8F).withValues(alpha: tileOpacity),
        ]),
    );
    canvas.restore();

    // Fork: a quick resonance shiver (decaying) while the waves ripple, like a struck tuning fork.
    final ringT = _ring.transform(progress);
    final decay = math.pow(1 - ringT, 2).toDouble();
    final shiver = progress < _hold ? math.sin(ringT * math.pi * 14) * decay : 0.0;

    final forkPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 76
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white.withValues(alpha: math.min(tileOpacity * 1.3, 1));
    canvas.save();
    // Pivot on the stem so the tines sway as one, a few degrees.
    canvas.translate(512, 770);
    canvas.rotate(shiver * 0.035);
    canvas.translate(-512, -770);
    canvas.drawPath(_fork, forkPaint);
    canvas.restore();

    // Sound waves: the resting arcs stay put, and echoes ripple outward from them and fade, like a struck fork.
    final arcAlpha = math.min(tileOpacity * 1.3, 1.0);
    for (final side in [(_leftArc, -1.0), (_rightArc, 1.0)]) {
      canvas.drawPath(side.$1, _arcPaint(arcAlpha));
      for (var wave = 0; wave < 3; wave++) {
        final start = 0.04 + wave * 0.15;
        final t = Interval(start, start + 0.38, curve: Curves.easeOutCubic).transform(progress);
        if (t <= 0 || t >= 1) continue;
        canvas.save();
        canvas.translate(t * 110 * side.$2, 0);
        canvas.drawPath(side.$1, _arcPaint(arcAlpha * (1 - t) * 0.8));
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(LaunchLogoPainter old) => old.progress != progress || old.background != background;
}
