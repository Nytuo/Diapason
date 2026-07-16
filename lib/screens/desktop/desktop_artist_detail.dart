import 'package:diapason/components/MusicScreen/item_wrapper.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/desktop/desktop_album_detail.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/artist_content_provider.dart';
import 'package:diapason/services/audio_service_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class DesktopArtistDetail extends ConsumerWidget {
  const DesktopArtistDetail({super.key, required this.artist});

  final BaseItemDto artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = DesktopThemeScope.of(context);
    final albumsAsync = ref.watch(getPerformingArtistAlbumsProvider(artist: artist));
    final albums = albumsAsync.valueOrNull ?? [];

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
                    borderRadius: BorderRadius.circular(100),
                    child: SizedBox(width: 160, height: 160, child: AlbumImage(item: artist)),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "ARTIST",
                          style: TextStyle(color: p.accent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          artist.name ?? "Unknown",
                          style: TextStyle(color: p.textPrimary, fontSize: 32, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "${albums.length} albums",
                          style: TextStyle(color: p.textSecondary, fontSize: 14),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            FilledButton.icon(
                              style: FilledButton.styleFrom(backgroundColor: p.accent, foregroundColor: p.textInverse),
                              onPressed: () => GetIt.instance<AudioServiceHelper>().startInstantMixForArtists([artist]),
                              icon: const Icon(TablerIcons.player_play_filled, size: 18),
                              label: const Text("Play mix"),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              tooltip: "More",
                              color: p.textSecondary,
                              icon: const Icon(TablerIcons.dots, size: 20),
                              onPressed: () => openItemMenu(context: context, item: artist),
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
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            sliver: SliverToBoxAdapter(
              child: Text(
                "Albums",
                style: TextStyle(color: p.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          if (albumsAsync.isLoading)
            const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.78,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => ItemWrapper(item: albums[index], isGrid: true),
                  childCount: albums.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
