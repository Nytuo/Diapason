import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Something the Siri Remote (or a D-pad) can land on and press. [builder] says how it looks when focused.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.onPressed,
    required this.builder,
    this.autofocus = false,
    this.onLongPress,
  });

  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final Widget Function(BuildContext context, bool focused) builder;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        onLongPress: widget.onLongPress,
        child: widget.builder(context, _focused),
      ),
    );
  }
}

/// A pill-shaped button with an icon and a label.
class TvPillButton extends StatelessWidget {
  const TvPillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 14.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28.0),
          color: scheme.primary.withValues(alpha: focused ? 0.22 : 0.10),
          border: Border.all(color: focused ? scheme.onSurface : Colors.transparent, width: 3.0),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(width: 10.0),
            Text(label, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

/// A round avatar with an initial, the way profiles are shown.
class TvAvatar extends StatelessWidget {
  const TvAvatar({
    super.key,
    required this.color,
    required this.initial,
    this.size = 120.0,
    this.focused = false,
    this.icon,
  });

  final Color color;
  final String initial;
  final double size;
  final bool focused;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      alignment: Alignment.center,
      child: icon != null
          ? Icon(icon, color: Colors.white, size: size * 0.45)
          : Text(
              initial,
              style: TextStyle(color: Colors.white, fontSize: size * 0.45, fontWeight: FontWeight.w600),
            ),
    );
  }
}
