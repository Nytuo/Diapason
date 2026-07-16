import 'package:diapason/components/album_image.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/desktop/desktop_transport_controls.dart';
import 'package:diapason/services/current_album_image_provider.dart';
import 'package:diapason/services/media_state_stream.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class DesktopMiniPlayer extends ConsumerWidget {
  const DesktopMiniPlayer({super.key, required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 0),
                child: Row(
                  children: [
                    Text("MINI PLAYER",
                        style: TextStyle(color: p.textTertiary, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                    const Spacer(),
                    IconButton(
                      iconSize: 18,
                      tooltip: "Restore window",
                      color: p.textSecondary,
                      icon: const Icon(TablerIcons.arrows_maximize),
                      onPressed: onExit,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: item == null
                            ? Container(color: p.surface, child: Icon(TablerIcons.disc, size: 64, color: p.textTertiary))
                            : AlbumImage(imageListenable: currentAlbumImageProvider),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  children: [
                    Text(
                      item?.title ?? "No track playing",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item?.artist ?? "—",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              DesktopSeekBar(duration: item?.duration ?? Duration.zero),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: DesktopTransportControls(playing: playing, showShuffleRepeat: false, playSize: 30, iconSize: 24),
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}
