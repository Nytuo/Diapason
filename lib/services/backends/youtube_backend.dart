import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:get_it/get_it.dart';

class YouTubeBackend implements MediaBackend {
  YouTubeBackend();

  YouTubeService get _youtube => GetIt.instance<YouTubeService>();

  @override
  final MediaSourceConfig config = MediaSourceConfig(
    sourceId: YouTubeService.sourceId,
    kind: MediaSourceKind.youtube,
    name: "YouTube",
  );

  @override
  String get sourceId => config.sourceId;

  @override
  bool get isConnected => true;

  @override
  Future<bool> ping() async => true;

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
    transcoding: false,
    playlists: false,
    favorites: false,
    playbackReporting: false,
    instantMix: false,
    serverLyrics: false,
    search: false,
  );

  @override
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
  }) async => const [];

  @override
  Future<List<BaseItemDto>> getRadioStations() async => const [];

  @override
  Future<List<BaseItemDto>> getInstantMix(BaseItemDto item, {int? limit}) async => const [];

  @override
  Future<BaseItemDto> createPlaylist(String name, {List<BaseItemId> itemIds = const [], bool isPublic = true}) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  @override
  Future<void> addToPlaylist(BaseItemDto playlist, List<BaseItemId> itemIds) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  @override
  Future<void> removeFromPlaylist(BaseItemDto playlist, List<String> playlistItemIds) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  @override
  Future<void> updatePlaylistMetadata(BaseItemDto playlist, {String? name, bool? isPublic}) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  @override
  Future<void> reorderPlaylist(BaseItemDto playlist, List<BaseItemId> orderedItemIds) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  @override
  Future<BaseItemDto?> getItemById(BaseItemId id) async => null;

  @override
  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) async {
    final stream = await _youtube.streamUrl(item);
    if (stream == null) {
      throw StateError("Could not resolve a YouTube stream for '${item.name}'.");
    }
    return PlayableSource(stream.url, container: stream.container);
  }

  @override
  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) =>
      resolveStream(item, transcode: false);

  @override
  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) =>
      _youtube.thumbnail(item);

  @override
  Map<String, String> get imageHeaders => const {};

  @override
  Future<LyricDto?> getLyrics(BaseItemDto item) async => null;

  @override
  Future<void> setFavorite(BaseItemDto item, {required bool isFavorite}) async {}

  @override
  Future<void> reportPlaybackStart(BaseItemDto item, {String? playSessionId}) async {}

  @override
  Future<void> reportPlaybackProgress(
    BaseItemDto item, {
    required Duration position,
    required bool isPaused,
    String? playSessionId,
  }) async {}

  @override
  Future<void> reportPlaybackStopped(BaseItemDto item, {required Duration position, String? playSessionId}) async {}

  @override
  Future<void> logout() async {}
}
