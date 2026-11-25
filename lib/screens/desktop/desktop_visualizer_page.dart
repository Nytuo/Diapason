import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:diapason/components/visuals/milkdrop_tuning_sliders.dart';
import 'package:diapason/components/visuals/milkdrop_view.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

/// The animated visual over the whole window, with the track and a few controls that fade out while the mouse rests.
/// Space plays/pauses, the arrows change preset, F toggles fullscreen and Escape leaves.
class DesktopVisualizerPage extends ConsumerStatefulWidget {
  const DesktopVisualizerPage({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<DesktopVisualizerPage> createState() => _DesktopVisualizerPageState();
}

class _DesktopVisualizerPageState extends ConsumerState<DesktopVisualizerPage> {
  static final _log = Logger("DesktopVisualizerPage");

  final _preset = ValueNotifier(MilkdropPreset.plasma);
  final _focus = FocusNode();
  bool _controlsVisible = true;
  bool _fullscreen = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
    unawaited(windowManager.isFullScreen().then((value) => mounted ? setState(() => _fullscreen = value) : null));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _preset.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _onActivity() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _step(int delta) {
    final count = MilkdropPreset.values.length;
    FinampSetters.setMilkdropPreset((_preset.value.index + delta + count) % count);
    _onActivity();
  }

  void _toggleCycle() {
    final cycling = FinampSettingsHelper.finampSettings.milkdropPreset < 0;
    FinampSetters.setMilkdropPreset(cycling ? _preset.value.index : -1);
    _onActivity();
  }

  Future<void> _setFullscreen(bool value) async {
    try {
      await windowManager.setFullScreen(value);
      if (mounted) setState(() => _fullscreen = value);
    } catch (e) {
      _log.warning("Could not change fullscreen: $e");
    }
  }

  Future<void> _close() async {
    if (_fullscreen) await _setFullscreen(false);
    widget.onClose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      unawaited(_close());
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _step(1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
    } else if (key == LogicalKeyboardKey.keyF) {
      unawaited(_setFullscreen(!_fullscreen));
    } else if (key == LogicalKeyboardKey.space) {
      unawaited(GetIt.instance<MusicPlayerBackgroundTask>().togglePlayback());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final p = DesktopThemeScope.of(context);
    final cycling = ref.watch(finampSettingsProvider.milkdropPreset) < 0;
    final handler = GetIt.instance<MusicPlayerBackgroundTask>();

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
        onHover: (_) => _onActivity(),
        child: GestureDetector(
          onTap: _onActivity,
          onDoubleTap: () => _setFullscreen(!_fullscreen),
          child: Material(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MilkdropView(showStatus: true, currentPreset: _preset),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Stack(
                      children: [
                        Positioned(
                          top: 16,
                          right: 16,
                          child: _Bar(
                            children: [
                              IconButton(
                                tooltip: l10n.visualPreviousPreset,
                                color: Colors.white,
                                icon: const Icon(TablerIcons.chevron_left),
                                onPressed: () => _step(-1),
                              ),
                              ValueListenableBuilder(
                                valueListenable: _preset,
                                builder: (context, preset, _) => Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  child: Text(preset.label(l10n), style: const TextStyle(color: Colors.white)),
                                ),
                              ),
                              IconButton(
                                tooltip: l10n.visualNextPreset,
                                color: Colors.white,
                                icon: const Icon(TablerIcons.chevron_right),
                                onPressed: () => _step(1),
                              ),
                              IconButton(
                                tooltip: l10n.visualAnimatedPresetCycle,
                                color: cycling ? p.accent : Colors.white,
                                icon: const Icon(TablerIcons.repeat),
                                onPressed: _toggleCycle,
                              ),
                              IconButton(
                                tooltip: "Fine-tune this preset",
                                color: Colors.white,
                                icon: const Icon(TablerIcons.adjustments),
                                onPressed: () => showMilkdropTuningDialog(context, _preset.value),
                              ),
                              IconButton(
                                tooltip: _fullscreen ? l10n.visualExitFullscreen : l10n.visualFullscreen,
                                color: Colors.white,
                                icon: Icon(_fullscreen ? TablerIcons.arrows_minimize : TablerIcons.arrows_maximize),
                                onPressed: () => _setFullscreen(!_fullscreen),
                              ),
                              IconButton(
                                tooltip: l10n.visualClose,
                                color: Colors.white,
                                icon: const Icon(TablerIcons.x),
                                onPressed: _close,
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          right: 24,
                          bottom: 24,
                          child: _Transport(handler: handler, onActivity: _onActivity),
                        ),
                        Positioned(
                          left: 24,
                          bottom: 24,
                          right: 280,
                          child: StreamBuilder<MediaItem?>(
                            stream: handler.mediaItem,
                            initialData: handler.mediaItem.valueOrNull,
                            builder: (context, snapshot) {
                              final item = snapshot.data;
                              if (item == null) return const SizedBox.shrink();
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      shadows: [Shadow(blurRadius: 8)],
                                    ),
                                  ),
                                  if (item.artist != null)
                                    Text(
                                      item.artist!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 18,
                                        shadows: [Shadow(blurRadius: 8)],
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// Previous / play-pause / next over the visual.
class _Transport extends StatelessWidget {
  const _Transport({required this.handler, required this.onActivity});

  final MusicPlayerBackgroundTask handler;
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    return _Bar(
      children: [
        IconButton(
          color: Colors.white,
          icon: const Icon(TablerIcons.player_skip_back_filled),
          onPressed: () {
            onActivity();
            unawaited(handler.skipToPrevious());
          },
        ),
        StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          initialData: handler.playbackState.valueOrNull,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            return IconButton(
              color: Colors.white,
              iconSize: 32,
              icon: Icon(playing ? TablerIcons.player_pause_filled : TablerIcons.player_play_filled),
              onPressed: () {
                onActivity();
                unawaited(handler.togglePlayback());
              },
            );
          },
        ),
        IconButton(
          color: Colors.white,
          icon: const Icon(TablerIcons.player_skip_forward_filled),
          onPressed: () {
            onActivity();
            unawaited(handler.skipToNext());
          },
        ),
      ],
    );
  }
}
