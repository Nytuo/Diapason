import 'dart:math';

import 'package:diapason/screens/ipod/ipod_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gaimon/gaimon.dart';

class ClickWheel extends StatefulWidget {
  const ClickWheel({super.key, required this.controller, this.diameter = 260});

  final IpodController controller;
  final double diameter;

  @override
  State<ClickWheel> createState() => _ClickWheelState();
}

class _ClickWheelState extends State<ClickWheel> {
  static const _stepDegrees = 24.0;

  double? _lastAngle;
  double _accumulated = 0;

  double get _centerRadius => widget.diameter * 0.19;

  Offset _vector(Offset local) => local - Offset(widget.diameter / 2, widget.diameter / 2);
  double _radius(Offset local) => _vector(local).distance;
  double _angle(Offset local) {
    final v = _vector(local);
    return atan2(v.dy, v.dx) * 180 / pi;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final local = details.localPosition;
    if (_radius(local) <= _centerRadius) return;

    final angle = _angle(local);
    final last = _lastAngle;

    if (last != null) {
      var delta = angle - last;
      if (delta > 180) delta -= 360;
      if (delta < -180) delta += 360;

      _accumulated += delta;
      while (_accumulated >= _stepDegrees) {
        widget.controller.scroll(1);
        _accumulated -= _stepDegrees;
        _tick();
      }
      while (_accumulated <= -_stepDegrees) {
        widget.controller.scroll(-1);
        _accumulated += _stepDegrees;
        _tick();
      }
    }
    _lastAngle = angle;
  }

  void _onPanEnd(_) {
    _lastAngle = null;
    _accumulated = 0;
  }

  void _tick() => Gaimon.selection();
  void _pop() => Gaimon.light();

  void _onTapUp(TapUpDetails details) {
    final local = details.localPosition;
    final radius = _radius(local);

    if (radius <= _centerRadius) {
      widget.controller.select();
      _pop();
      return;
    }
    if (radius > widget.diameter / 2) return;

    final angle = _angle(local);
    _pop();
    if (angle >= -45 && angle < 45) {
      widget.controller.next();
    } else if (angle >= 45 && angle < 135) {
      widget.controller.playPause();
    } else if (angle >= -135 && angle < -45) {
      widget.controller.menuBack();
    } else {
      widget.controller.previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final diameter = widget.diameter;
    const label = Color(0xFF474747);

    return GestureDetector(
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      onTapUp: _onTapUp,
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(colors: [Color(0xFFF7F7F7), Color(0xFFDBDBDB)]),
                border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(0, 3)),
                ],
              ),
            ),

            Positioned(
              top: diameter * 0.06,
              child: const Text(
                "MENU",
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: label, letterSpacing: 1),
              ),
            ),
            Positioned(
              bottom: diameter * 0.07,
              child: const Icon(TablerIcons.player_play, size: 18, color: label),
            ),
            Positioned(
              left: diameter * 0.07,
              child: const Icon(TablerIcons.player_skip_back, size: 18, color: label),
            ),
            Positioned(
              right: diameter * 0.07,
              child: const Icon(TablerIcons.player_skip_forward, size: 18, color: label),
            ),

            Container(
              width: _centerRadius * 2,
              height: _centerRadius * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(colors: [Color(0xFFFCFCFC), Color(0xFFE0E0E0)]),
                border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 2)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
