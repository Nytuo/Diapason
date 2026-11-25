import 'dart:async';

import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/menus/playlist_actions_menu.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_models.dart';
import 'package:diapason/models/music_slices.dart';
import 'package:diapason/screens/album_screen.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/audio_service_helper.dart';
import 'package:diapason/services/favorite_provider.dart';
import 'package:diapason/services/music_providers.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Remembers where the pointer last went down, so a menu opened by a click or a long press can appear there.
class DesktopPointerAnchor {
  static Offset? _last;
  static bool _installed = false;

  static void ensureInstalled() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
      if (event is PointerDownEvent) _last = event.position;
    });
  }

  static Offset get last => _last ?? Offset.zero;
}

/// Whether [item] has a desktop menu (otherwise the caller opens the full menu).
bool desktopMenuSupports(BaseItemDto item) => switch (BaseItemDtoType.fromItem(item)) {
  BaseItemDtoType.track || BaseItemDtoType.album || BaseItemDtoType.artist || BaseItemDtoType.playlist => true,
  _ => false,
};

/// A compact popup menu at the pointer: the everyday actions on a track, album, artist or playlist, with "More…"
/// opening the full menu. Replaces the mobile bottom sheet on desktop.
Future<void> showDesktopItemMenu({
  required BuildContext context,
  required BaseItemDto item,
  required VoidCallback openFullMenu,
  QueueItemSource? source,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final p = DesktopThemeScope.of(context);
  final type = BaseItemDtoType.fromItem(item);
  final isTrack = type == BaseItemDtoType.track;
  final isFavorite = container.read(isFavoriteProvider(item));
  final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject()! as RenderBox;
  // showMenu places the menu relative to its navigator's overlay, so use the root one (the whole window) and
  // convert the pointer's global position into it; the content area's navigator is inset in the panel.
  final at = overlay.globalToLocal(DesktopPointerAnchor.last);
  final position = RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size);

  PopupMenuItem<String> entry(String value, IconData icon, String label) => PopupMenuItem<String>(
    value: value,
    height: 38,
    child: Row(
      children: [
        Icon(icon, size: 17, color: p.textSecondary),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: p.textPrimary, fontSize: 13.5)),
      ],
    ),
  );

  final artistId = isTrack ? item.artistItems?.firstOrNull : item.albumArtists?.firstOrNull;
  final choice = await showMenu<String>(
    context: context,
    position: position,
    useRootNavigator: true,
    color: p.bgSecondary,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: p.panelBorder),
    ),
    items: [
      entry("play", TablerIcons.player_play, "Play"),
      if (!isTrack) entry("shuffle", TablerIcons.arrows_shuffle, "Shuffle"),
      entry("next", TablerIcons.player_track_next, "Play next"),
      entry("queue", TablerIcons.playlist_add, "Add to queue"),
      const PopupMenuDivider(height: 8),
      entry(
        "favorite",
        isFavorite ? TablerIcons.heart_filled : TablerIcons.heart,
        isFavorite ? "Remove favorite" : "Favorite",
      ),
      if (isTrack) entry("playlist", TablerIcons.playlist, "Add to playlist…"),
      entry("mix", TablerIcons.wand, "Instant mix"),
      if (isTrack && item.albumId != null) entry("album", TablerIcons.disc, "Go to album"),
      if (artistId != null) entry("artist", TablerIcons.user, "Go to artist"),
      const PopupMenuDivider(height: 8),
      entry("more", TablerIcons.dots, "More…"),
    ],
  );
  if (choice == null) return;

  final queue = GetIt.instance<QueueService>();

  Future<PlayableSlice> slice() async {
    if (isTrack) return PlayableSlice.simple([item], source ?? QueueItemSource.fromBaseItem(item));
    final playable = switch (type) {
      BaseItemDtoType.album => Album.fromItem(item) as FinampPlayable,
      BaseItemDtoType.artist => Artist.fromItem(item),
      _ => Playlist.fromItem(item),
    };
    return container.read(getPlayableSliceProvider(item: playable, startingOffset: 0).future);
  }

  try {
    switch (choice) {
      case "play":
        await queue.startSlicePlayback(await slice());
      case "shuffle":
        await queue.startSlicePlayback((await slice()).shuffle());
      case "next":
        await queue.addNext(await slice());
        GlobalSnackbar.message((c) => "Playing next", isConfirmation: true);
      case "queue":
        await queue.addToQueue(await slice());
        GlobalSnackbar.message((c) => "Added to queue", isConfirmation: true);
      case "favorite":
        container.read(isFavoriteProvider(item).notifier).toggleFavorite();
      case "playlist":
        if (context.mounted) await showPlaylistActionsMenu(context: context, items: [item]);
      case "mix":
        await GetIt.instance<AudioServiceHelper>().startInstantMixForItem(item);
      case "album":
        final album = await GetIt.instance<AggregateBackend>().getItemById(item.albumId!);
        if (context.mounted && album != null) {
          unawaited(DesktopRouter.pushNamed(context, AlbumScreen.routeName, arguments: album));
        }
      case "artist":
        if (context.mounted) {
          unawaited(
            DesktopRouter.pushNamed(
              context,
              ArtistScreen.routeName,
              arguments: BaseItemDto(id: artistId!.id, name: artistId.name, type: "MusicArtist"),
            ),
          );
        }
      case "more":
        openFullMenu();
    }
  } catch (e) {
    GlobalSnackbar.error(e);
  }
}
