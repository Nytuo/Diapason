import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/artist_content_provider.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/jellyfin_backend.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/jellyfin_api_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'item_amount_provider.g.dart';

@riverpod
Future<(int, BaseItemDtoType)> itemAmount(
  Ref ref, {
  required BaseItemDto baseItem,
  bool showTrackCountForArtists = false,
}) async {
  final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final downloadsService = GetIt.instance<DownloadsService>();
  final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;

  BaseItemDtoType itemType = BaseItemDtoType.fromItem(baseItem);

  final isJellyfin = GetIt.instance<BackendRegistry>().forItem(baseItem) is JellyfinBackend;
  if (!isJellyfin && !ref.watch(finampSettingsProvider.isOffline)) {
    return switch (itemType) {
      BaseItemDtoType.artist => (baseItem.childCount ?? 0, BaseItemDtoType.album),
      BaseItemDtoType.genre => (baseItem.childCount ?? 0, BaseItemDtoType.album),
      BaseItemDtoType.album || BaseItemDtoType.playlist => (baseItem.childCount ?? 0, BaseItemDtoType.track),
      _ => (baseItem.childCount ?? 0, BaseItemDtoType.unknown),
    };
  }

  late int itemCount;

  switch (itemType) {
    case BaseItemDtoType.artist:
      showTrackCountForArtists =
          showTrackCountForArtists || ref.watch(finampSettingsProvider.defaultArtistType) == ArtistType.artist;
      if (ref.watch(finampSettingsProvider.isOffline)) {
        var items = await (showTrackCountForArtists
            ? ref.watch(getArtistAlbumsProvider(artist: baseItem, libraryFilter: library?.id).future)
            : ref.watch(getPerformingArtistTracksProvider(artist: baseItem, libraryFilter: library?.id).future));
        itemCount = items.length;
      } else {
        var items = await jellyfinApiHelper.getItemsWithTotalRecordCount(
          libraryFilter: library?.id,
          parentItem: baseItem,
          includeItemTypes: showTrackCountForArtists
              ? BaseItemDtoType.track.jellyfinName
              : BaseItemDtoType.album.jellyfinName,
          limit: 1,
          artistType: showTrackCountForArtists ? ArtistType.artist : ArtistType.albumArtist,
        );
        itemCount = items.totalRecordCount;
      }
      if (itemCount == 0) {
        if (!showTrackCountForArtists) {
          // If artist has 0 albums, try counting tracks instead
          return await ref.watch(itemAmountProvider(baseItem: baseItem, showTrackCountForArtists: true).future);
        }
      }
      return (itemCount, showTrackCountForArtists ? BaseItemDtoType.track : BaseItemDtoType.album);
    case BaseItemDtoType.genre:
      if (ref.watch(finampSettingsProvider.isOffline)) {
        var items = await downloadsService.getAllCollections(
          includeItemTypes: [BaseItemDtoType.album],
          fullyDownloaded: ref.watch(finampSettingsProvider.onlyShowFullyDownloaded),
          viewFilter: library?.id,
          nullableViewFilters: ref.watch(finampSettingsProvider.showDownloadsWithUnknownLibrary),
          genreFilter: baseItem.id,
        );
        itemCount = items.nonNulls.length;
      } else {
        var items = await jellyfinApiHelper.getItemsWithTotalRecordCount(
          parentItem: library,
          genreFilter: baseItem.id,
          limit: 1,
          includeItemTypes: BaseItemDtoType.album.jellyfinName,
        );
        itemCount = items.totalRecordCount;
      }
      return (itemCount, BaseItemDtoType.album);
    case BaseItemDtoType.album:
    case BaseItemDtoType.playlist:
      return (baseItem.childCount ?? 0, BaseItemDtoType.track);
    default:
      return (baseItem.childCount ?? 0, BaseItemDtoType.unknown);
  }
}

@riverpod
BaseItemDtoType childItemType(Ref ref, BaseItemDto item) {
  return switch (BaseItemDtoType.fromItem(item)) {
    BaseItemDtoType.album => BaseItemDtoType.track,
    BaseItemDtoType.artist =>
      ref.watch(finampSettingsProvider.defaultArtistType) == ArtistType.albumArtist
          ? BaseItemDtoType.album
          : BaseItemDtoType.track,
    BaseItemDtoType.genre => BaseItemDtoType.album,
    BaseItemDtoType.playlist => BaseItemDtoType.track,
    _ => BaseItemDtoType.unknown,
  };
}
