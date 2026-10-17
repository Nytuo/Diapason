import 'package:diapason/components/tv_now_playing_pill.dart';
import 'package:diapason/utils/device_form_factor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// On a TV the focused control is the only clue to where you are. Material's own focus tint is faint, so this paints a
/// clear Material outline around whatever has focus, whichever widget it is, and follows it as lists scroll. It only paints: no
/// widget is added or rebuilt as focus moves.
class TvFocusRing extends StatefulWidget {
  const TvFocusRing({super.key, required this.child});

  final Widget child;

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing> {
  final _key = GlobalKey();
  final _rect = ValueNotifier<Rect?>(null);

  @override
  void initState() {
    super.initState();
    if (DeviceFormFactorDetector.current.isTv) SchedulerBinding.instance.addPostFrameCallback(_track);
  }

  @override
  void dispose() {
    _rect.dispose();
    super.dispose();
  }

  void _track(Duration _) {
    if (!mounted) return;
    Rect? rect = _rect.value;
    try {
      final focusContext = FocusManager.instance.primaryFocus?.context;
      final target = focusContext != null && focusContext.mounted ? focusContext.findRenderObject() : null;
      final self = _key.currentContext?.findRenderObject();
      rect = null;
      if (tvOwnChromeScreens.value == 0 &&
          target is RenderBox &&
          target.attached &&
          target.hasSize &&
          !target.debugNeedsLayout &&
          self is RenderBox &&
          self.attached &&
          self.hasSize &&
          !self.debugNeedsLayout) {
        // Text fields and the like also take focus; an outline around a whole screen or page is noise.
        final candidate = self.globalToLocal(target.localToGlobal(Offset.zero)) & target.size;
        if (candidate.width * candidate.height < self.size.width * self.size.height * 0.5) rect = candidate;
      }
    } catch (_) {
      // The focused widget was being rebuilt or removed this frame; keep the last ring and try again.
    }
    if (rect != _rect.value) _rect.value = rect;
    SchedulerBinding.instance.addPostFrameCallback(_track);
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: _key,
      foregroundPainter: _RingPainter(_rect, Theme.of(context).colorScheme.onSurface),
      child: widget.child,
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.rect, this.color) : super(repaint: rect);

  final ValueNotifier<Rect?> rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect.value;
    if (r == null) return;
    // Material 3 style focus indicator: a clean 3 dp outline set just off the element, no glow.
    final rrect = RRect.fromRectAndRadius(r.inflate(3.0), const Radius.circular(12.0));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color;
}
