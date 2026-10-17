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
    final accent = Theme.of(context).colorScheme.primary;
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      builder: (context, focused) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 14.0),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8.0), color: focused ? accent : Colors.white10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 8.0),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 16.0)),
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: focused ? Colors.white : Colors.transparent, width: 4.0),
        boxShadow: focused ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 24.0)] : null,
      ),
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
