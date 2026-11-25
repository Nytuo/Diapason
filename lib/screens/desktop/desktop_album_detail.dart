import 'package:diapason/screens/desktop/desktop_kit.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/components/MusicScreen/item_wrapper.dart';
import 'package:diapason/components/MusicScreen/sort_and_filter_row.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_slices.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/album_screen_provider.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class DesktopAlbumDetail extends ConsumerStatefulWidget {
  const DesktopAlbumDetail({super.key, required this.parent});

  final BaseItemDto parent;

  @override
  ConsumerState<DesktopAlbumDetail> createState() => _DesktopAlbumDetailState();
}

class _DesktopAlbumDetailState extends ConsumerState<DesktopAlbumDetail> {
  final _sortController = SortAndFilterController.trackSettings(ContentType.inPlaylist);
  String _query = "";

  BaseItemDto get parent => widget.parent;

  /// "Artist · year · N tracks", the artist names linking to their artist page.
  Widget _subtitle(BuildContext context, DesktopPalette p, int trackCount) {
    final style = TextStyle(color: p.textSecondary, fontSize: 14);
    final artists = (parent.albumArtists ?? []).where((a) => a.id.raw.isNotEmpty).toList();
    final rest = [if (parent.productionYear != null) "${parent.productionYear}", "$trackCount tracks"].join("  ·  ");
    if (artists.isEmpty) {
      return Text(
        [if (parent.albumArtist != null) parent.albumArtist, rest].whereType<String>().join("  ·  "),
        style: style,
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (i, artist) in artists.indexed) ...[
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => DesktopRouter.pushNamed(
                context,
                ArtistScreen.routeName,
                arguments: BaseItemDto(id: artist.id, name: artist.name, type: "MusicArtist"),
              ),
              child: Text(
                artist.name ?? "",
                style: style.copyWith(color: p.textPrimary, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          if (i < artists.length - 1) Text(", ", style: style),
        ],
        Text("  ·  $rest", style: style),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final isPlaylist = BaseItemDtoType.fromItem(parent) == BaseItemDtoType.playlist;
    final sortConfig = ref
        .watch(resolveSortProvider(_sortController))
        .copyWithSearch(isPlaylist && _query.trim().isNotEmpty ? _query : null);
    final tracksAsync = isPlaylist
        ? ref.watch(getSortedPlaylistTracksProvider(parent, sortConfig))
        : ref.watch(getAlbumOrPlaylistTracksProvider(parent));
    final (allTracks, playableTracks) = tracksAsync.value ?? (null, null);
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
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: (p.isDark ? Colors.white : Colors.black).withValues(alpha: p.isDark ? 0.05 : 0.04),
                border: Border(bottom: BorderSide(color: p.borderSubtle)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DesktopDetailBackButton(color: p.textSecondary),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(DesktopMetrics.radiusCard),
                            boxShadow: [
                              BoxShadow(
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                                color: Colors.black.withValues(alpha: 0.35),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(DesktopMetrics.radiusCard),
                            child: SizedBox(width: 220, height: 220, child: AlbumImage(item: parent)),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                isPlaylist ? "PLAYLIST" : "ALBUM",
                                style: TextStyle(
                                  color: p.accent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                parent.name ?? "Unknown",
                                style: TextStyle(
                                  color: p.textPrimary,
                                  fontSize: 34,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: -0.5,
                                  height: 1.1,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _subtitle(context, p, display.length),
                              const SizedBox(height: 20),
                              Row(
                                children: [
                                  FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: p.accent,
                                      foregroundColor: p.textInverse,
                                    ),
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
                  ],
                ),
              ),
            ),
          ),
          if (isPlaylist)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 320,
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        style: TextStyle(color: p.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: "Search in playlist",
                          hintStyle: TextStyle(color: p.textTertiary),
                          prefixIcon: Icon(TablerIcons.search, size: 16, color: p.textTertiary),
                          filled: true,
                          fillColor: p.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Material(
                        type: MaterialType.transparency,
                        child: SortAndFilterRow(tabType: ContentType.inPlaylist, controller: _sortController),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (tracksAsync.isLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else
            SliverList.builder(
              itemCount: display.length,
              itemBuilder: (context, i) =>
                  DesktopTrackRow(item: display[i], index: i, queue: queue, source: source, showNumber: !isPlaylist),
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
