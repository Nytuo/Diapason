import 'package:diapason/components/PlayerScreen/spectrum_visualizer.dart';
import 'package:diapason/screens/blurred_player_screen_background.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/desktop/desktop_track_info.dart';
import 'package:diapason/screens/desktop/desktop_transport_controls.dart';
import 'package:diapason/screens/lyrics_screen.dart';
import 'package:diapason/services/current_album_image_provider.dart';
import 'package:diapason/services/media_state_stream.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class DesktopFullscreenPlayer extends ConsumerStatefulWidget {
  const DesktopFullscreenPlayer({super.key, required this.onExit});

  final VoidCallback onExit;

  @override
  ConsumerState<DesktopFullscreenPlayer> createState() => _DesktopFullscreenPlayerState();
}

class _DesktopFullscreenPlayerState extends ConsumerState<DesktopFullscreenPlayer> {
  bool _showLyrics = false;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    return Material(
      color: p.bg,
      child: StreamBuilder<MediaState>(
        stream: mediaStateStream,
        initialData: MediaState(
          audioHandler.mediaItem.valueOrNull,
          audioHandler.playbackState.value,
          audioHandler.fadeState.value,
        ),
        builder: (context, snapshot) {
          final state = snapshot.data!;
          final item = state.mediaItem;
          final playing = state.playbackState.playing;
          return Stack(
            children: [
              const Positioned.fill(child: BlurredPlayerScreenBackground()),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 220,
                child: IgnorePointer(
                  child: Opacity(opacity: 0.5, child: RepaintBoundary(child: SpectrumVisualizer())),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(64, 48, 48, 48),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: item == null
                                      ? Container(color: p.surface, child: Icon(TablerIcons.disc, size: 96, color: p.textTertiary))
                                      : AlbumImage(imageListenable: currentAlbumImageProvider),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 56),
                          Expanded(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 460),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item?.title ?? "No track playing",
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: p.textPrimary, fontSize: 32, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    item?.artist ?? "—",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: p.textSecondary, fontSize: 18),
                                  ),
                                  const SizedBox(height: 12),
                                  const DesktopTrackInfoLine(fontSize: 13),
                                  const SizedBox(height: 28),
                                  DesktopSeekBar(duration: item?.duration ?? Duration.zero),
                                  const SizedBox(height: 20),
                                  DesktopTransportControls(playing: playing, playSize: 34, iconSize: 28),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showLyrics)
                    Container(
                      width: 420,
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: p.borderSubtle)),
                        color: p.bgSecondary,
                      ),
                      child: const LyricsView(),
                    ),
                ],
              ),
              Positioned(
                top: 16,
                right: 16,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: "Lyrics",
                      color: _showLyrics ? p.accent : p.textSecondary,
                      icon: const Icon(TablerIcons.microphone_2),
                      onPressed: () => setState(() => _showLyrics = !_showLyrics),
                    ),
                    IconButton(
                      tooltip: "Exit fullscreen",
                      color: p.textSecondary,
                      icon: const Icon(TablerIcons.arrows_minimize),
                      onPressed: widget.onExit,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
