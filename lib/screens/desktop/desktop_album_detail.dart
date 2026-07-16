import 'package:diapason/components/AlbumScreen/album_screen_content.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/components/MusicScreen/item_wrapper.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_slices.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/album_screen_provider.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class DesktopAlbumDetail extends ConsumerWidget {
  const DesktopAlbumDetail({super.key, required this.parent});

  final BaseItemDto parent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = DesktopThemeScope.of(context);
    final isPlaylist = BaseItemDtoType.fromItem(parent) == BaseItemDtoType.playlist;
    final tracksAsync = ref.watch(getAlbumOrPlaylistTracksProvider(parent));
    final (allTracks, playableTracks) = tracksAsync.valueOrNull ?? (null, null);
    final display = allTracks ?? [];
    final queue = playableTracks ?? [];

    final source = QueueItemSource.fromBaseItem(parent);

    Future<void> play({required bool shuffle}) async {
      if (queue.isEmpty) return;
      await GetIt.instance<QueueService>().startPlayback(
        items: queue,
        source: source,
        order: shuffle ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear,
      );
    }

    Future<void> enqueue({required bool next}) async {
      if (queue.isEmpty) return;
      try {
        final slice = PlayableSlice.simple(queue, source);
        final queueService = GetIt.instance<QueueService>();
        if (next) {
          await queueService.addNext(slice);
        } else {
          await queueService.addToQueue(slice);
        }
        GlobalSnackbar.message((c) => next ? "Playing next" : "Added to queue", isConfirmation: true);
      } catch (e) {
        GlobalSnackbar.error(e);
      }
    }

    return Material(
      color: p.bg,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: DesktopDetailBackButton(color: p.textSecondary),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(width: 200, height: 200, child: AlbumImage(item: parent)),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isPlaylist ? "PLAYLIST" : "ALBUM",
                          style: TextStyle(color: p.accent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          parent.name ?? "Unknown",
                          style: TextStyle(color: p.textPrimary, fontSize: 32, fontWeight: FontWeight.bold, height: 1.1),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          [
                            if (parent.albumArtist != null) parent.albumArtist,
                            if (parent.productionYear != null) "${parent.productionYear}",
                            "${display.length} tracks",
                          ].whereType<String>().join("  ·  "),
                          style: TextStyle(color: p.textSecondary, fontSize: 14),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            FilledButton.icon(
                              style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.textInverse),
                              onPressed: () => play(shuffle: false),
                              icon: const Icon(TablerIcons.player_play_filled, size: 18),
                              label: const Text("Play"),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: p.textPrimary,
                                side: BorderSide(color: p.border),
                              ),
                              onPressed: () => play(shuffle: true),
                              icon: const Icon(TablerIcons.arrows_shuffle, size: 18),
                              label: const Text("Shuffle"),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              tooltip: "Play next",
                              color: p.textSecondary,
                              icon: const Icon(TablerIcons.player_track_next, size: 20),
                              onPressed: () => enqueue(next: true),
                            ),
                            IconButton(
                              tooltip: "Add to queue",
                              color: p.textSecondary,
                              icon: const Icon(TablerIcons.playlist_add, size: 20),
                              onPressed: () => enqueue(next: false),
                            ),
                            IconButton(
                              tooltip: "More",
                              color: p.textSecondary,
                              icon: const Icon(TablerIcons.dots, size: 20),
                              onPressed: () => openItemMenu(context: context, item: parent),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (tracksAsync.isLoading)
            const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: TracksSliverList(
                childrenForList: display,
                childrenForQueue: queue,
                parent: parent,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class DesktopDetailBackButton extends StatelessWidget {
  const DesktopDetailBackButton({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    if (!(Navigator.of(context).canPop())) return const SizedBox.shrink();
    return TextButton.icon(
      style: TextButton.styleFrom(foregroundColor: color),
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const Icon(TablerIcons.chevron_left, size: 18),
      label: const Text("Back"),
    );
  }
}
