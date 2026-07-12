import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';

abstract class MediaBackend {
  MediaSourceConfig get config;

  String get sourceId => config.sourceId;

  BackendCapabilities get capabilities;

  bool get isConnected;

  Future<bool> ping();

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
  });

  Future<BaseItemDto?> getItemById(BaseItemId id);

  Future<List<BaseItemDto>> getInstantMix(BaseItemDto item, {int? limit}) async => const [];

  Future<List<BaseItemDto>> getRadioStations() async => const [];

  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId});

  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile});

  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format});

  Map<String, String> get imageHeaders;

  Future<LyricDto?> getLyrics(BaseItemDto item);

  Future<void> setFavorite(BaseItemDto item, {required bool isFavorite});

  Future<BaseItemDto> createPlaylist(String name, {List<BaseItemId> itemIds = const [], bool isPublic = true}) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  Future<void> addToPlaylist(BaseItemDto playlist, List<BaseItemId> itemIds) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  Future<void> removeFromPlaylist(BaseItemDto playlist, List<String> playlistItemIds) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  Future<void> updatePlaylistMetadata(BaseItemDto playlist, {String? name, bool? isPublic}) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  Future<void> reorderPlaylist(BaseItemDto playlist, List<BaseItemId> orderedItemIds) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  Future<void> reportPlaybackStart(BaseItemDto item, {String? playSessionId});
  Future<void> reportPlaybackProgress(
    BaseItemDto item, {
    required Duration position,
    required bool isPaused,
    String? playSessionId,
  });
  Future<void> reportPlaybackStopped(BaseItemDto item, {required Duration position, String? playSessionId});

  Future<void> logout();
}
