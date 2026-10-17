import 'package:audio_service/audio_service.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:get_it/get_it.dart';
import 'package:diapason/components/now_playing_bar.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

/// Focus node of the now-playing bar at the top of the screen.
final FocusNode tvBarFocusNode = FocusNode(debugLabel: "TV now playing bar");

/// Arrow keys only move focus within the current page, so the bar above it could never be reached. This adds the
/// missing link: Up from the top edge of a page jumps to the bar, Down from the bar returns to where focus was.
KeyEventResult tvBarKeyHandler(FocusNode node, KeyEvent event) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  final key = event.logicalKey;
  final barShown = tvBarFocusNode.context != null && tvBarFocusNode.context!.mounted;

  if (key == LogicalKeyboardKey.arrowUp && barShown && !tvBarFocusNode.hasFocus) {
    final moved = FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.up) ?? false;
    if (!moved) {
      tvBarFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  if (key == LogicalKeyboardKey.arrowDown && barShown && tvBarFocusNode.hasFocus) {
    final navigatorContext = GlobalSnackbar.navigatorState?.context;
    if (navigatorContext != null) {
      final scope = FocusScope.of(navigatorContext);
      final target =
          scope.focusedChild ??
          scope.traversalDescendants.where((n) => n.canRequestFocus && !n.skipTraversal).firstOrNull;
      target?.requestFocus();
    }
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

/// How many player screens are open; the pill below hides itself while one is.
final ValueNotifier<int> tvPlayerScreensOpen = ValueNotifier(0);

/// How many TV-native screens (profile picker, setup) are showing. They draw their own focus and have no use for the
/// pill or the app-wide focus outline.
final ValueNotifier<int> tvOwnChromeScreens = ValueNotifier(0);

/// Put around the player screen so the TV's now-playing pill knows to step aside.
class TvPlayerPresence extends StatefulWidget {
  const TvPlayerPresence({super.key, required this.child, this.counter});

  final Widget child;

  /// Which counter to hold up while this is on screen; the player counter by default.
  final ValueNotifier<int>? counter;

  @override
  State<TvPlayerPresence> createState() => _TvPlayerPresenceState();
}

class _TvPlayerPresenceState extends State<TvPlayerPresence> {
  late final ValueNotifier<int> _counter = widget.counter ?? tvPlayerScreensOpen;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) => _counter.value++);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.addPostFrameCallback((_) => _counter.value--);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// On a TV the bar at the bottom of each page is hard to reach with a remote, so the same now-playing bar sits at the
/// top of every screen instead, in the layout rather than floating over it: always there, and one press opens Now
/// Playing.
const double _barHeight = 94.0;

/// Space above the bar: TVs crop the edges of the picture, and the bar should not sit hard against the top.
const double _barTopMargin = 28.0;

/// The bar's tooltips and menus need an Overlay, which a widget placed above the app's Navigator does not have, so it
/// gets one of its own.
class _OverlayHost extends StatefulWidget {
  const _OverlayHost({required this.child});

  final Widget child;

  @override
  State<_OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<_OverlayHost> {
  late final OverlayEntry _entry = OverlayEntry(builder: (context) => widget.child);

  @override
  void dispose() {
    _entry.remove();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

class TvNowPlayingStrip extends StatelessWidget {
  const TvNowPlayingStrip({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: tvOwnChromeScreens,
      builder: (context, own, _) => ValueListenableBuilder<int>(
        valueListenable: tvPlayerScreensOpen,
        builder: (context, open, _) {
          if (open > 0 || own > 0) return const SizedBox.shrink();
          return ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: StreamBuilder<MediaItem?>(
              stream: GetIt.instance<MusicPlayerBackgroundTask>().mediaItem,
              builder: (context, snapshot) => snapshot.data == null
                  ? const SizedBox.shrink()
                  : const Padding(
                      padding: EdgeInsets.only(top: _barTopMargin),
                      child: SizedBox(
                        height: _barHeight,
                        child: _OverlayHost(child: NowPlayingBar(tvTop: true)),
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }
}
