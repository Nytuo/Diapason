import 'package:diapason/screens/watch/watch_rotary.dart';
import 'package:flutter/material.dart';

/// Shared look of the watch app: black (ambient and OLED friendly), big targets, lists inset for round screens and
/// scrolled with the crown.
class WatchColors {
  static const background = Colors.black;
  static const surface = Color(0xFF1C1C1E);
  static const text = Colors.white;
  static const secondary = Colors.white60;
  static const accent = Color(0xFF8AB4F8);
}

/// Horizontal inset that keeps content inside a round screen (about the width of the circle's edge at the top of a
/// list row).
double watchSideInset(BuildContext context) => MediaQuery.sizeOf(context).shortestSide * 0.1;

/// A page of the watch app: black, with a scrolled list of [children] under an optional [title]. The first and last
/// rows can scroll to the middle of a round screen.
class WatchListPage extends StatefulWidget {
  const WatchListPage({super.key, this.title, required this.children, this.controller, this.onEndReached});

  final String? title;
  final List<Widget> children;
  final ScrollController? controller;

  /// Called when the list is scrolled near its end (to load more).
  final VoidCallback? onEndReached;

  @override
  State<WatchListPage> createState() => _WatchListPageState();
}

class _WatchListPageState extends State<WatchListPage> {
  late final ScrollController _controller = widget.controller ?? ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    final callback = widget.onEndReached;
    if (callback == null || !_controller.hasClients) return;
    if (_controller.position.extentAfter < 300) callback();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final side = watchSideInset(context);
    return Scaffold(
      backgroundColor: WatchColors.background,
      body: WatchRotaryScroll(
        controller: _controller,
        child: ListView(
          controller: _controller,
          padding: EdgeInsets.fromLTRB(side, size.height * 0.12, side, size.height * 0.25),
          children: [
            if (widget.title case final title?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: WatchColors.accent, fontSize: 15.0, fontWeight: FontWeight.w600),
                ),
              ),
            ...widget.children,
          ],
        ),
      ),
    );
  }
}

/// A big, rounded list row.
class WatchTile extends StatelessWidget {
  const WatchTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null || onLongPress != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Material(
        color: selected ? WatchColors.accent.withValues(alpha: 0.25) : WatchColors.surface,
        borderRadius: BorderRadius.circular(26.0),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52.0),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 6.0),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 10.0)],
                  if (leading == null && icon != null) ...[
                    Icon(icon, size: 22.0, color: enabled ? WatchColors.text : WatchColors.secondary),
                    const SizedBox(width: 10.0),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: enabled ? WatchColors.text : WatchColors.secondary,
                            fontSize: 14.0,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (subtitle case final s? when s.isNotEmpty)
                          Text(
                            s,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: WatchColors.secondary, fontSize: 12.0),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Centered secondary text (empty states, hints, errors).
class WatchMessage extends StatelessWidget {
  const WatchMessage(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 4.0),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: WatchColors.secondary, fontSize: 13.0),
    ),
  );
}

/// A round icon button big enough for a finger.
class WatchRoundButton extends StatelessWidget {
  const WatchRoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 44.0,
    this.filled = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool filled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: filled ? WatchColors.text : WatchColors.surface,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: size * 0.5, color: filled ? WatchColors.background : WatchColors.text),
        ),
      ),
    );
    return tooltip == null ? button : Semantics(label: tooltip, button: true, child: button);
  }
}

/// A small square of artwork from [url] (with [headers]), or an icon when there is none or it does not load.
class WatchArt extends StatelessWidget {
  const WatchArt({super.key, this.url, this.headers, this.size = 36.0, this.fallback = Icons.music_note});

  final Uri? url;
  final Map<String, String>? headers;
  final double size;
  final IconData fallback;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: Colors.white10,
      child: Icon(fallback, size: size * 0.55, color: WatchColors.secondary),
    );
    final u = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 5),
      child: u == null
          ? placeholder
          : Image.network(
              u.toString(),
              headers: headers,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}

/// Shows a short message at the bottom of a watch screen.
void watchToast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.0)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        margin: EdgeInsets.symmetric(horizontal: watchSideInset(context) * 1.5, vertical: 12.0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.0)),
      ),
    );
}
