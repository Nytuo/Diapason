import 'package:collection/collection.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

class AggregateBackend {
  static final _log = Logger("AggregateBackend");

  BackendRegistry get _registry => GetIt.instance<BackendRegistry>();

  Iterable<MediaBackend> get sources => _registry.enabled;

  Future<List<T>> _fanOut<T>(Future<List<T>> Function(MediaBackend) call) async {
    final backends = sources.toList();
    if (backends.isEmpty) return const [];

    final results = await Future.wait(
      backends.map((backend) async {
        try {
          return await call(backend);
        } catch (e) {
          _log.warning("Source ${backend.config.name} failed; skipping it: $e");
          return <T>[];
        }
      }),
    );
    return results.expand((r) => r).toList();
  }

  Future<List<BaseItemDto>> getItems({
    BaseItemDto? parentItem,
    BaseItemId? libraryFilter,
    String? includeItemTypes,
    String? sortBy,
    String? sortOrder,
    String? searchTerm,
    String? filters,
    BaseItemId? genreFilter,
    bool? isFavorite,
    ArtistType? artistType,
    int? startIndex,
    int? limit,
  }) async {
    if (parentItem != null) {
      final backend = _registry.forItem(parentItem);
      if (backend == null) return const [];
      return backend.getItems(
        parentItem: parentItem,
        libraryFilter: libraryFilter,
        includeItemTypes: includeItemTypes,
        sortBy: sortBy,
        sortOrder: sortOrder,
        searchTerm: searchTerm,
        filters: filters,
        genreFilter: genreFilter,
        isFavorite: isFavorite,
        artistType: artistType,
        startIndex: startIndex,
        limit: limit,
      );
    }

    final backends = sources.toList();
    if (backends.isEmpty) return const [];

    if (backends.length == 1) {
      return backends.single.getItems(
        libraryFilter: libraryFilter,
        includeItemTypes: includeItemTypes,
        sortBy: sortBy,
        sortOrder: sortOrder,
        searchTerm: searchTerm,
        filters: filters,
        genreFilter: genreFilter,
        isFavorite: isFavorite,
        artistType: artistType,
        startIndex: startIndex,
        limit: limit,
      );
    }

    final offset = startIndex ?? 0;
    final window = limit == null ? null : offset + limit;

    final items = await _fanOut(
      (backend) => backend.getItems(
        libraryFilter: libraryFilter,
        includeItemTypes: includeItemTypes,
        sortBy: sortBy,
        sortOrder: sortOrder,
        searchTerm: searchTerm,
        filters: filters,
        genreFilter: genreFilter,
        isFavorite: isFavorite,
        artistType: artistType,
        startIndex: 0,
        limit: window,
      ),
    );

    items.sort((a, b) => (a.nameForSorting ?? "").compareTo(b.nameForSorting ?? ""));
    if (sortOrder?.toLowerCase().contains("desc") ?? false) {
      final reversed = items.reversed.toList();
      items
        ..clear()
        ..addAll(reversed);
    }

    if (offset >= items.length) return const [];
    return items.sublist(offset, window == null ? items.length : window.clamp(0, items.length));
  }

  Future<BaseItemDto?> getItemById(BaseItemId id) async => _registry.forItemId(id)?.getItemById(id);

  Future<List<BaseItemDto>> getInstantMix(BaseItemDto item, {int? limit}) async {
    final backend = _registry.forItem(item);
    if (backend == null || !backend.capabilities.instantMix) return const [];

    try {
      return await backend.getInstantMix(item, limit: limit);
    } catch (e) {
      _log.warning("Instant mix from ${backend.config.name} failed: $e");
      return const [];
    }
  }

  Future<List<BaseItemDto>> getRadioStations() => _fanOut((backend) => backend.getRadioStations());

  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) =>
      _registry.backendFor(item).resolveStream(item, transcode: transcode, playSessionId: playSessionId);

  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) =>
      _registry.backendFor(item).resolveDownload(item, transcodingProfile: transcodingProfile);

  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) => _registry
      .forItem(item)
      ?.imageUrl(item, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality, format: format);

  Future<LyricDto?> getLyrics(BaseItemDto item) async => _registry.forItem(item)?.getLyrics(item);

  Future<bool> setFavorite(BaseItemDto item, {required bool isFavorite}) async {
    final backend = _registry.forItem(item);
    if (backend == null || !backend.capabilities.favorites) return false;

    await backend.setFavorite(item, isFavorite: isFavorite);
    return true;
  }

  Iterable<MediaBackend> get playlistCapableSources => sources.where((b) => b.capabilities.playlists);

  Future<BaseItemDto?> createPlaylist(
    String name, {
    List<BaseItemId> itemIds = const [],
    MediaBackend? source,
    bool isPublic = true,
  }) async {
    final backend =
        source ?? (itemIds.isNotEmpty ? _registry.forItemId(itemIds.first) : null) ?? playlistCapableSources.firstOrNull;
    if (backend == null || !backend.capabilities.playlists) return null;

    final ownItemIds = itemIds.where((id) => _registry.forItemId(id) == backend).toList();
    return backend.createPlaylist(name, itemIds: ownItemIds, isPublic: isPublic);
  }

  Future<bool> addToPlaylist(BaseItemDto playlist, List<BaseItemId> itemIds) async {
    final backend = _registry.forItem(playlist);
    if (backend == null || !backend.capabilities.playlists) return false;

    final ownItemIds = itemIds.where((id) => _registry.forItemId(id) == backend).toList();
    if (ownItemIds.isEmpty) return false;

    await backend.addToPlaylist(playlist, ownItemIds);
    return true;
  }

  Future<bool> removeFromPlaylist(BaseItemDto playlist, List<String> playlistItemIds) async {
    final backend = _registry.forItem(playlist);
    if (backend == null || !backend.capabilities.playlists) return false;

    await backend.removeFromPlaylist(playlist, playlistItemIds);
    return true;
  }

  Future<bool> updatePlaylistMetadata(BaseItemDto playlist, {String? name, bool? isPublic}) async {
    final backend = _registry.forItem(playlist);
    if (backend == null || !backend.capabilities.playlists) return false;

    await backend.updatePlaylistMetadata(playlist, name: name, isPublic: isPublic);
    return true;
  }

  Future<bool> reorderPlaylist(BaseItemDto playlist, List<BaseItemId> orderedItemIds) async {
    final backend = _registry.forItem(playlist);
    if (backend == null || !backend.capabilities.playlists) return false;

    final ownItemIds = orderedItemIds.where((id) => _registry.forItemId(id) == backend).toList();
    await backend.reorderPlaylist(playlist, ownItemIds);
    return true;
  }
}
