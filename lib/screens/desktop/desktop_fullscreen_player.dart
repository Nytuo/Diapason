import 'package:diapason/components/PlayerScreen/progress_slider.dart';
import 'package:diapason/components/PlayerScreen/spectrum_visualizer.dart';
import 'package:diapason/screens/desktop/desktop_ambient_background.dart';
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

  /// The cover's colours and a heavily blurred copy of the cover, under a veil that darkens towards the edges so the
  /// text stays legible whatever the artwork.
  Widget _background(BuildContext context, DesktopPalette p) {
    final scheme = Theme.of(context).colorScheme;
    final image = ref.watch(currentAlbumImageProvider).image;
    const fade = Duration(milliseconds: 900);
    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerLowest),
            DesktopColorField(scheme: scheme, duration: p.motion(fade)),
            Opacity(
              opacity: 0.85,
              child: DesktopBlurredCover(image: image, duration: p.motion(fade)),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.25),
                    Colors.black.withValues(alpha: 0.35),
                    Colors.black.withValues(alpha: 0.65),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
              _background(context, p),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 220,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.5,
                    child: RepaintBoundary(child: SpectrumVisualizer(placement: SpectrumPlacement.strip)),
                  ),
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
                                child: SpectrumCoverRing(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(18),
                                      boxShadow: [
                                        BoxShadow(
                                          blurRadius: 60,
                                          spreadRadius: 2,
                                          offset: const Offset(0, 24),
                                          color: Colors.black.withValues(alpha: 0.55),
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(18),
                                      child: item == null
                                          ? Container(
                                              color: p.surface,
                                              child: Icon(TablerIcons.disc, size: 96, color: p.textTertiary),
                                            )
                                          : AlbumImage(imageListenable: currentAlbumImageProvider),
                                    ),
                                  ),
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
                                    style: TextStyle(
                                      color: p.textPrimary,
                                      fontSize: 40,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: -0.8,
                                      height: 1.1,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    item?.artist ?? "—",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: p.textSecondary, fontSize: 20),
                                  ),
                                  const SizedBox(height: 12),
                                  const DesktopTrackInfoLine(fontSize: 13),
                                  const SizedBox(height: 28),
                                  DesktopSeekBar(
                                    duration: item?.duration ?? Duration.zero,
                                    chapters: chaptersFromMediaItem(item),
                                  ),
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 56, 20, 20),
                      // No BackdropFilter: the background is already a blurred bitmap, and a live blur would be
                      // recomputed every frame under the animated spectrum.
                      child: Container(
                        width: 440,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(DesktopMetrics.radiusPanel + 6),
                          border: Border.all(color: p.panelBorder),
                        ),
                        child: const LyricsView(),
                      ),
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
