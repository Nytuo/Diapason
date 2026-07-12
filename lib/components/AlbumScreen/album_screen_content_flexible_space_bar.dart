import 'package:diapason/components/AlbumScreen/item_info.dart';
import 'package:diapason/components/MusicScreen/sort_and_filter_row.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/menus/components/playbackActions/playback_action_row.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AlbumMenuItems {
  addFavorite,
  removeFavorite,
  addToMixList,
  removeFromMixList,
  playNext,
  addToNextUp,
  shuffleNext,
  shuffleToNextUp,
  addToQueue,
  shuffleToQueue,
}

class AlbumScreenContentFlexibleSpaceBar extends ConsumerWidget {
  const AlbumScreenContentFlexibleSpaceBar({
    super.key,
    required this.parentItem,
    required this.items,
    required this.controller,
  });

  final BaseItemDto parentItem;
  final List<BaseItemDto>? items;
  final SortAndFilterController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sortConfig = ref.watch(resolveSortProvider(controller));

    return FlexibleSpaceBar(
      background: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    SizedBox(height: 125, child: AlbumImage(item: parentItem, tapToZoom: true)),
                    const SizedBox(width: 4),
                    Expanded(
                      flex: 2,
                      child: ItemInfo(item: parentItem, itemTracks: items, sortConfigController: controller),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                PlaybackActionRow(
                  compactLayout: true,
                  item: BaseItemDtoType.fromItem(parentItem) == BaseItemDtoType.playlist
                      ? Playlist(parentItem, sortConfig: sortConfig)
                      : Album.fromItem(parentItem),
                  popContext: false,
                ),
                if (BaseItemDtoType.fromItem(parentItem) == BaseItemDtoType.playlist) ...[
                  SizedBox(height: 10),
                  SortAndFilterRow(tabType: ContentType.inPlaylist, controller: controller),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
