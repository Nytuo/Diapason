import 'dart:async';

import 'package:diapason/components/confirmation_prompt_dialog.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/track_menu.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/album_screen.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/screens/downloads_screen.dart';
import 'package:diapason/screens/genre_screen.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/services/album_screen_provider.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/feedback_helper.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

void navigateToSource(BuildContext context, QueueItemSource source) {
  switch (source.type) {
    case QueueItemSourceType.album:
    case QueueItemSourceType.nextUpAlbum:
    case QueueItemSourceType.albumMix:
      Navigator.of(context).pushNamed(AlbumScreen.routeName, arguments: source.item);
      break;
    case QueueItemSourceType.artist:
    case QueueItemSourceType.nextUpArtist:
    case QueueItemSourceType.artistMix:
      Navigator.of(context).pushNamed(ArtistScreen.routeName, arguments: source.item);
      break;
    case QueueItemSourceType.genre:
    case QueueItemSourceType.nextUpGenre:
    case QueueItemSourceType.genreMix:
      Navigator.of(context).pushNamed(GenreScreen.routeName, arguments: source.item);
      break;
    case QueueItemSourceType.playlist:
    case QueueItemSourceType.nextUpPlaylist:
      Navigator.of(context).pushNamed(AlbumScreen.routeName, arguments: source.item);
      break;
    case QueueItemSourceType.allTracks:
    case QueueItemSourceType.favorites:
      Navigator.of(context).pushNamed(MusicScreen.routeName, arguments: ContentType.tracks);
      break;
    case QueueItemSourceType.track:
    case QueueItemSourceType.trackMix:
      if (source.item != null) {
        showModalTrackMenu(context: context, item: source.item!);
      }
    case QueueItemSourceType.collection:
    case QueueItemSourceType.collectionMix:
      if (source.item != null) {
        // showModalCollectionMenu(context: context, item: source.item!);
        Navigator.of(context).push(
          MaterialPageRoute<MusicScreen>(
            builder: (context) => MusicScreen(
              singleTabConfig: HomeScreenSectionConfiguration(
                base: CollectionHomeSection(
                  itemId: source.item!.id,
                  libraryId: GetIt.instance<FinampUserHelper>().currentUser?.currentViewId ?? allLibraryPlaceholder,
                  contentType: ContentType.mixed,
                ),
                customSectionTitle: source.item!.name ?? AppLocalizations.of(context)!.unknownName,
                sortConfig: SortAndFilterConfiguration.defaultSort,
              ),
            ),
          ),
        );
      }
    case QueueItemSourceType.radio:
      final radioSource = GetIt.instance<QueueService>().getQueue().source;
      if (radioSource.item == null) {
        break;
      }
      switch (BaseItemDtoType.fromItem(radioSource.item!)) {
        case BaseItemDtoType.track:
          showModalTrackMenu(context: context, item: radioSource.item!);
          break;
        case BaseItemDtoType.album:
        case BaseItemDtoType.playlist:
          Navigator.of(context).pushNamed(AlbumScreen.routeName, arguments: radioSource.item);
          break;
        case BaseItemDtoType.artist:
          Navigator.of(context).pushNamed(ArtistScreen.routeName, arguments: radioSource.item);
          break;
        case BaseItemDtoType.genre:
          Navigator.of(context).pushNamed(GenreScreen.routeName, arguments: radioSource.item);
          break;
        case BaseItemDtoType.collection:
          Navigator.of(context).push(
            MaterialPageRoute<MusicScreen>(
              builder: (context) => MusicScreen(
                singleTabConfig: HomeScreenSectionConfiguration(
                  base: CollectionHomeSection(
                    itemId: radioSource.item!.id,
                    libraryId: GetIt.instance<FinampUserHelper>().currentUser?.currentViewId ?? allLibraryPlaceholder,
                    contentType: ContentType.mixed,
                  ),
                  customSectionTitle: radioSource.item!.name ?? AppLocalizations.of(context)!.unknownName,
                  sortConfig: SortAndFilterConfiguration.defaultSort,
                ),
              ),
            ),
          );
        case BaseItemDtoType.noItem:
        case BaseItemDtoType.library:
        case BaseItemDtoType.folder:
        case BaseItemDtoType.musicVideo:
        case BaseItemDtoType.audioBook:
        case BaseItemDtoType.tvEpisode:
        case BaseItemDtoType.video:
        case BaseItemDtoType.movie:
        case BaseItemDtoType.trailer:
        case BaseItemDtoType.unknown:
          break;
      }
      break;
    case QueueItemSourceType.homeScreenSection:
      final sectionInfo = FinampSettingsHelper.finampSettings.homeScreenConfiguration.sections.singleWhere(
        (section) => section.id == source.id,
      );
      Navigator.of(
        context,
      ).push(MaterialPageRoute<MusicScreen>(builder: (context) => MusicScreen(singleTabConfig: sectionInfo)));
      break;
    case QueueItemSourceType.downloads:
      Navigator.of(context).pushNamed(DownloadsScreen.routeName);
      break;
    case QueueItemSourceType.nextUp:
    case QueueItemSourceType.formerNextUp:
    case QueueItemSourceType.remoteClient:
    case QueueItemSourceType.unknown:
      break;
    case QueueItemSourceType.filteredList:
    case QueueItemSourceType.queue:
      FeedbackHelper.feedback(FeedbackType.warning);
      GlobalSnackbar.message((scaffold) => AppLocalizations.of(context)!.notImplementedYet);
  }
}

Future<bool> removeFromPlaylist(
  BuildContext context,
  BaseItemDto item,
  BaseItemDto parent,
  String playlistItemId, {
  required bool confirm,
}) async {
  bool isConfirmed = !confirm;
  if (confirm) {
    await showDialog(
      context: context,
      builder: (context) => ConfirmationPromptDialog(
        promptText: AppLocalizations.of(
          context,
        )!.removeFromPlaylistPrompt(item.name ?? "item", parent.name ?? "playlist"),
        confirmButtonText: AppLocalizations.of(context)!.removeFromPlaylistConfirm,
        onConfirmed: () {
          isConfirmed = true;
        },
      ),
    );
  }
  if (isConfirmed) {
    try {
      await GetIt.instance<AggregateBackend>().removeFromPlaylist(parent, [playlistItemId]);

      // re-sync playlist to delete removed item if not required anymore
      final downloadsService = GetIt.instance<DownloadsService>();
      unawaited(
        downloadsService.resync(
          DownloadStub.fromItem(type: DownloadItemType.collection, item: parent),
          null,
          keepSlow: true,
        ),
      );

      playlistRemovalsCache.add(parent.id.raw + playlistItemId);

      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.removedFromPlaylist, isConfirmation: true);
      return true;
    } catch (err) {
      GlobalSnackbar.error(err);
      return false;
    }
  }
  return false;
}

Future<bool> addItemsToPlaylist(BuildContext context, List<BaseItemDto> items, BaseItemDto parent) async {
  // Albums and playlists do not seem to add in the correct order, so manually fetch and add all children instead of
  // relying on server to do that.
  if (items.length == 1 &&
      [BaseItemDtoType.album, BaseItemDtoType.playlist].contains(BaseItemDtoType.fromItem(items.first))) {
    final children = await GetIt.instance<ProviderContainer>().read(
      getAlbumOrPlaylistTracksProvider(items.first).future,
    );
    items = children.$1;
  }

  //TODO request server to return the new playlist item id
  final added = await GetIt.instance<AggregateBackend>().addToPlaylist(parent, items.map((item) => item.id).toList());
  if (!added) {
    throw Exception("Couldn't add to '${parent.name}': its source doesn't support editing playlists.");
  }

  // re-sync playlist to download added item if needed
  final downloadsService = GetIt.instance<DownloadsService>();
  unawaited(
    downloadsService.resync(
      DownloadStub.fromItem(type: DownloadItemType.collection, item: parent),
      null,
      keepSlow: true,
    ),
  );

  GlobalSnackbar.message((scaffold) => AppLocalizations.of(context)!.confirmAddedToPlaylist, isConfirmation: true);
  return true;
}

// Removed playlist items will persist in queue with playlist source.  Store removed items
// to hide remove from playlist prompt on those items.
final Set<String> playlistRemovalsCache = {};

bool queueItemInPlaylist(FinampQueueItem? queueItem) {
  if (queueItem == null) {
    return false;
  }
  final baseItem = queueItem.baseItem;
  return [QueueItemSourceType.playlist, QueueItemSourceType.nextUpPlaylist].contains(queueItem.source.type) &&
      baseItem.playlistItemId != null &&
      !playlistRemovalsCache.contains(queueItem.source.id + (baseItem.playlistItemId ?? ""));
}
