import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/jellyfin_api_helper.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

class JellyfinBackend implements MediaBackend {
  JellyfinBackend(this.config);

  static final _log = Logger("JellyfinBackend");

  @override
  final MediaSourceConfig config;

  @override
  String get sourceId => config.sourceId;

  final JellyfinApiHelper _api = GetIt.instance<JellyfinApiHelper>();
  FinampUserHelper get _users => GetIt.instance<FinampUserHelper>();

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
    transcoding: true,
    playlists: true,
    favorites: true,
    playbackReporting: true,
    instantMix: true,
    serverLyrics: true,
    search: true,
  );

  @override
  bool get isConnected => config.accessToken.isNotEmpty;

  @override
  Future<bool> ping() async {
    try {
      await _api.getItems(limit: 1);
      return true;
    } catch (e) {
      _log.fine("Ping failed for $config: $e");
      return false;
    }
  }

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
  }) async {
    final items = await _api.getItems(
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
    return items ?? const [];
  }

  @override
  Future<List<BaseItemDto>> getRadioStations() async => const [];

  @override
  Future<BaseItemDto?> getItemById(BaseItemId id) => _api.getItemByIdBatched(id);

  @override
  Future<List<BaseItemDto>> getInstantMix(BaseItemDto item, {int? limit}) async =>
      await _api.getInstantMix(item, limit: limit) ?? const [];

  @override
  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) async {
    final base = Uri.parse(config.baseUrl);
    final path = List<String>.from(base.pathSegments);
    final query = Map<String, String>.from(base.queryParameters);
    query["ApiKey"] = config.accessToken;

    final settings = FinampSettingsHelper.finampSettings;

    if (transcode) {
      path.addAll(["Audio", item.id.nativeId, "main.m3u8"]);
      query.addAll({
        "audioCodec": settings.transcodingStreamingFormat.codec,
        "playSessionId": playSessionId ?? "",
        "audioSampleRate": settings.transcodingStreamingFormat.sampleRate.toString(),
        "segmentContainer": settings.transcodingStreamingFormat.container,
      });
      if (!settings.transcodingStreamingFormat.lossless) {
        query["audioBitRate"] = settings.transcodeBitrate.toString();
      }
      if (_shouldDownmix(settings.transcodingStreamingFormat.codec)) {
        query["maxAudioChannels"] = "2";
      }
    } else {
      path.addAll(["Items", item.id.nativeId, "File"]);
    }

    return PlayableSource(
      Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.port,
        userInfo: base.userInfo,
        pathSegments: path,
        queryParameters: query,
      ),
    );
  }

  @override
  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) async {
    final uri = _api.getTrackDownloadUrl(item: item, transcodingProfile: transcodingProfile);
    return PlayableSource(uri, headers: {"Authorization": _users.authorizationHeader});
  }

  static bool _shouldDownmix(String codec) {
    final setting = FinampSettingsHelper.finampSettings.multichannelHandlingSetting;
    return setting == MultichannelHandlingSetting.stereoDownmixAll ||
        (setting == MultichannelHandlingSetting.stereoDownmixLossy && codec != "flac");
  }

  @override
  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) =>
      _api.getImageUrl(item: item, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality, format: format);

  @override
  Map<String, String> get imageHeaders => {"Authorization": _users.authorizationHeader};

  @override
  Future<LyricDto?> getLyrics(BaseItemDto item) async {
    try {
      return await _api.getLyrics(itemId: item.id);
    } catch (e) {
      _log.fine("No lyrics from Jellyfin for ${item.name}: $e");
      return null;
    }
  }

  @override
  Future<void> setFavorite(BaseItemDto item, {required bool isFavorite}) async {
    if (isFavorite) {
      await _api.addFavorite(item.id);
    } else {
      await _api.removeFavorite(item.id);
    }
  }

  @override
  Future<BaseItemDto> createPlaylist(String name, {List<BaseItemId> itemIds = const [], bool isPublic = true}) async {
    final response = await _api.createNewPlaylist(
      NewPlaylist(
        name: name,
        ids: itemIds,
        userId: GetIt.instance<FinampUserHelper>().currentUser!.id,
        isPublic: isPublic,
      ),
    );
    final playlist = await _api.getItemByIdBatched(response.id!);
    if (playlist == null) {
      throw Exception("${config.name} did not return the playlist it just created.");
    }
    return playlist;
  }

  @override
  Future<void> addToPlaylist(BaseItemDto playlist, List<BaseItemId> itemIds) =>
      _api.addItemstoPlaylist(playlistId: playlist.id, ids: itemIds);

  @override
  Future<void> removeFromPlaylist(BaseItemDto playlist, List<String> playlistItemIds) =>
      _api.removeItemsFromPlaylist(playlistId: playlist.id, entryIds: playlistItemIds);

  @override
  Future<void> updatePlaylistMetadata(BaseItemDto playlist, {String? name, bool? isPublic}) => _api.updatePlaylist(
    itemId: playlist.id,
    newPlaylist: NewPlaylist(
      name: name,
      isPublic: isPublic,
      userId: GetIt.instance<FinampUserHelper>().currentUserId,
    ),
  );

  @override
  Future<void> reorderPlaylist(BaseItemDto playlist, List<BaseItemId> orderedItemIds) => _api.updatePlaylist(
    itemId: playlist.id,
    newPlaylist: NewPlaylist(ids: orderedItemIds, userId: GetIt.instance<FinampUserHelper>().currentUserId),
  );

  @override
  Future<void> reportPlaybackStart(BaseItemDto item, {String? playSessionId}) =>
      _api.reportPlaybackStart(_progress(item, Duration.zero, false, playSessionId));

  @override
  Future<void> reportPlaybackProgress(
    BaseItemDto item, {
    required Duration position,
    required bool isPaused,
    String? playSessionId,
  }) => _api.updatePlaybackProgress(_progress(item, position, isPaused, playSessionId));

  @override
  Future<void> reportPlaybackStopped(BaseItemDto item, {required Duration position, String? playSessionId}) =>
      _api.stopPlaybackProgress(_progress(item, position, false, playSessionId));

  PlaybackProgressInfo _progress(BaseItemDto item, Duration position, bool isPaused, String? playSessionId) =>
      PlaybackProgressInfo(
        itemId: BaseItemId(item.id.nativeId),
        isPaused: isPaused,
        isMuted: false,
        repeatMode: "RepeatNone",
        positionTicks: position.inMicroseconds * 10,
        playSessionId: playSessionId,
      );

  @override
  Future<void> logout() => _api.logoutCurrentUser();
}
