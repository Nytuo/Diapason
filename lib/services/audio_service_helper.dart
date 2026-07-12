import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/extensions/localizations.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/radio_service_helper.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart' as jellyfin_models;
import 'downloads_service.dart';
import 'finamp_settings_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';
import 'queue_service.dart';

/// Just some functions to make talking to AudioService a bit neater.
class AudioServiceHelper {
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _queueService = GetIt.instance<QueueService>();
  final _isarDownloader = GetIt.instance<DownloadsService>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final audioServiceHelperLogger = Logger("AudioServiceHelper");

  /// Shuffles every track in the user's current view.
  Future<void> shuffleAll({required bool onlyShowFavorites, BaseItemDto? genreFilter, int? itemCount}) async {
    List<jellyfin_models.BaseItemDto>? items;

    if (FinampSettingsHelper.finampSettings.isOffline) {
      // If offline, get a shuffled list of tracks from _downloadsHelper.
      // This is a bit inefficient since we have to get all of the tracks and
      // shuffle them before making a sublist, but I couldn't think of a better
      // way.
      items = (await _isarDownloader.getAllTracks(
        viewFilter: _finampUserHelper.currentUser?.currentView?.id,
        genreFilter: genreFilter?.id,
        onlyFavorites: onlyShowFavorites,
        nullableViewFilters: FinampSettingsHelper.finampSettings.showDownloadsWithUnknownLibrary,
      )).map((e) => e.baseItem!).toList();
      items.shuffle();
      final count = itemCount ?? FinampSettingsHelper.finampSettings.trackShuffleItemCount;
      if (items.length - 1 > count) {
        items = items.sublist(0, count);
      }
    } else {
      items = await GetIt.instance<AggregateBackend>().getItems(
        parentItem: _finampUserHelper.currentUser?.currentView,
        includeItemTypes: "Audio",
        filters: onlyShowFavorites ? "IsFavorite" : null,
        limit: itemCount ?? FinampSettingsHelper.finampSettings.trackShuffleItemCount,
        sortBy: "Random",
        genreFilter: genreFilter?.id,
      );
    }

    if (items != null) {
      QueueItemSource source = (genreFilter != null)
          ? QueueItemSource(
              type: QueueItemSourceType.genre,
              name: QueueItemSourceName(
                type: QueueItemSourceNameType.preTranslated,
                pretranslatedName: genreFilter.name,
              ),
              id: genreFilter.id,
              item: genreFilter,
            )
          : QueueItemSource.rawId(
              type: onlyShowFavorites ? QueueItemSourceType.favorites : QueueItemSourceType.allTracks,
              name: QueueItemSourceName(
                type: onlyShowFavorites ? QueueItemSourceNameType.yourLikes : QueueItemSourceNameType.shuffleAll,
              ),
              id: "shuffleAll",
            );

      await _queueService.startPlayback(items: items, source: source, order: FinampPlaybackOrder.shuffled);
    }
  }

  /// Start instant mix from item.
  Future<void> startInstantMixForItem(jellyfin_models.BaseItemDto item) async {
    try {
      final items = await GetIt.instance<AggregateBackend>().getInstantMix(item);
      if (items.isEmpty) {
        GlobalSnackbar.message((context) => context.l10n.noTracksFound);
      } else {
        await _queueService.startPlayback(
          items: items,
          source: QueueItemSource(
            type: switch (BaseItemDtoType.fromItem(item)) {
              BaseItemDtoType.track => QueueItemSourceType.trackMix,
              BaseItemDtoType.album => QueueItemSourceType.albumMix,
              BaseItemDtoType.artist => QueueItemSourceType.artistMix,
              BaseItemDtoType.genre => QueueItemSourceType.genreMix,
              BaseItemDtoType.collection => QueueItemSourceType.collectionMix,
              _ => QueueItemSourceType.unknown,
            },
            name: QueueItemSourceName(
              type: item.name != null ? QueueItemSourceNameType.mix : QueueItemSourceNameType.instantMix,
              localizationParameter: item.name ?? "",
            ),
            id: item.id,
            item: item,
          ),
          // instant mixes should have their order determined by the server
          order: FinampPlaybackOrder.linear,
        );
      }
    } catch (e) {
      audioServiceHelperLogger.severe(e);
      return Future.error(e);
    }
  }

  List<jellyfin_models.BaseItemDto> _mergeMixResults(List<List<jellyfin_models.BaseItemDto>> perSeedResults) {
    final merged = <jellyfin_models.BaseItemDto>[];
    final seenIds = <BaseItemId>{};
    var index = 0;
    var addedAny = true;
    while (addedAny) {
      addedAny = false;
      for (final seedResult in perSeedResults) {
        if (index >= seedResult.length) continue;
        final item = seedResult[index];
        addedAny = true;
        if (seenIds.add(item.id)) merged.add(item);
      }
      index++;
    }
    return merged;
  }

  /// Start instant mix from a selection of artists.
  Future<void> startInstantMixForArtists(List<BaseItemDto> artists) async {
    try {
      final aggregate = GetIt.instance<AggregateBackend>();
      final items = _mergeMixResults(await Future.wait(artists.map((a) => aggregate.getInstantMix(a))));
      if (items.isEmpty) {
        GlobalSnackbar.message((context) => context.l10n.noTracksFound);
      } else {
        await _queueService.startPlayback(
          items: items,
          source: QueueItemSource(
            type: QueueItemSourceType.artistMix,
            name: QueueItemSourceName(
              type: QueueItemSourceNameType.mix,
              localizationParameter: artists.map((e) => e.name).join(" & "),
            ),
            id: artists.first.id,
            item: artists.first,
          ),
          order: FinampPlaybackOrder
              .linear, // instant mixes should have their order determined by the server, especially to make sure the first item is the one that the mix is based off of
        );
        _jellyfinApiHelper.clearArtistMixBuilderList();
      }
    } catch (e) {
      audioServiceHelperLogger.severe(e);
      return Future.error(e);
    }
  }

  /// Start instant mix from a selection of albums.
  Future<void> startInstantMixForAlbums(List<BaseItemDto> albums) async {
    try {
      final aggregate = GetIt.instance<AggregateBackend>();
      final items = _mergeMixResults(await Future.wait(albums.map((a) => aggregate.getInstantMix(a))));
      if (items.isEmpty) {
        GlobalSnackbar.message((context) => context.l10n.noTracksFound);
      } else {
        await _queueService.startPlayback(
          items: items,
          source: QueueItemSource(
            type: QueueItemSourceType.albumMix,
            name: QueueItemSourceName(
              type: QueueItemSourceNameType.mix,
              localizationParameter: albums.map((e) => e.name).join(" & "),
            ),
            id: albums.first.id,
            item: albums.first,
          ),
          order: FinampPlaybackOrder
              .linear, // instant mixes should have their order determined by the server, especially to make sure the first item is the one that the mix is based off of
        );
        _jellyfinApiHelper.clearAlbumMixBuilderList();
      }
    } catch (e) {
      audioServiceHelperLogger.severe(e);
      return Future.error(e);
    }
  }

  /// Start instant mix from a selection of genres.
  Future<void> startInstantMixForGenres(List<BaseItemDto> genres) async {
    try {
      final aggregate = GetIt.instance<AggregateBackend>();
      final items = _mergeMixResults(await Future.wait(genres.map((g) => aggregate.getInstantMix(g))));
      if (items.isEmpty) {
        GlobalSnackbar.message((context) => context.l10n.noTracksFound);
      } else {
        await _queueService.startPlayback(
          items: items,
          source: QueueItemSource(
            type: QueueItemSourceType.genreMix,
            name: QueueItemSourceName(
              type: QueueItemSourceNameType.mix,
              localizationParameter: genres.map((e) => e.name).join(" & "),
            ),
            id: genres.first.id,
            item: genres.first,
          ),
          order: FinampPlaybackOrder
              .linear, // instant mixes should have their order determined by the server, especially to make sure the first item is the one that the mix is based off of
        );
        _jellyfinApiHelper.clearAlbumMixBuilderList();
      }
    } catch (e) {
      audioServiceHelperLogger.severe(e);
      return Future.error(e);
    }
  }

  /// Start continuous radio with a random track
  Future<void> startSurpriseMeMix() async {
    //TODO handle offline mode (continuous radio not available, and offline request needed) - maybe just hide this?
    if (FinampSettingsHelper.finampSettings.isOffline) {
      GlobalSnackbar.message((context) => context.l10n.notAvailableInOfflineMode);
      return;
    }
    final randomTracks = await GetIt.instance<AggregateBackend>().getItems(
      parentItem: _finampUserHelper.currentUser?.currentView,
      includeItemTypes: [BaseItemDtoType.track.jellyfinName].join(","),
      limit: 1,
      sortBy: SortBy.random.jellyfinName(ContentType.tracks),
    );
    if (randomTracks.isNotEmpty) {
      await GetIt.instance<QueueService>().startPlayback(
        items: randomTracks,
        source: QueueItemSource.fromBaseItem(randomTracks.first),
        skipRadioCacheInvalidation: false,
        order: FinampPlaybackOrder.linear,
      );
      FinampSetters.setRadioMode(RadioMode.continuous);
      toggleRadio(true);
    } else {
      GlobalSnackbar.message((context) => context.l10n.noTracksFound);
    }
  }

  Future<void> playRandomItem({bool favoritesOnly = false, List<BaseItemDtoType>? limitItemTypes}) async {
    // get random favorite (any item type)
    final randomFavorite = (await _jellyfinApiHelper.getItems(
      parentItem: _finampUserHelper.currentUser?.currentView,
      filters: favoritesOnly ? "IsFavorite" : null,
      // Jellyfin 10.10 and 10.11 use the [isFavorite] boolean filter instead of the list-based [filters] parameter for genres, so add that here
      // I guess part of the reason for this is that it's not possible to favorite a genre through the Jellyfin Web UI at all...
      isFavorite: favoritesOnly,
      includeItemTypes:
          (limitItemTypes ??
                  [
                    BaseItemDtoType.track,
                    BaseItemDtoType.album,
                    BaseItemDtoType.artist,
                    BaseItemDtoType.genre,
                    BaseItemDtoType.playlist,
                  ])
              .map((e) => e.jellyfinName)
              .join(","),
      sortBy: SortBy.random.jellyfinName(null),
      limit: 1,
    ))?.firstOrNull;

    if (randomFavorite == null) {
      GlobalSnackbar.message((context) => context.l10n.nothingFoundToPlay);
      return;
    }

    // if item is a collection, get its tracks, otherwise just play the item
    List<jellyfin_models.BaseItemDto> itemsToPlay;
    if (BaseItemDtoType.fromItem(randomFavorite) != BaseItemDtoType.track) {
      itemsToPlay =
          await _jellyfinApiHelper.getItems(
            parentItem: randomFavorite,
            includeItemTypes: [BaseItemDtoType.track].map((e) => e.jellyfinName).join(","),
            sortBy: SortBy.defaultOrder.jellyfinName(ContentType.tracks),
            sortOrder: SortOrder.ascending.name,
          ) ??
          [];
    } else {
      itemsToPlay = [randomFavorite];
    }

    await _queueService.startPlayback(items: itemsToPlay, source: QueueItemSource.fromBaseItem(randomFavorite));
  }
}
