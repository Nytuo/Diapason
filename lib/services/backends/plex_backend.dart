import 'dart:convert';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/item_sorter.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class PlexBackend implements MediaBackend {
  PlexBackend(this.config) : _map = ItemMapper(config.sourceId);

  static final _log = Logger("PlexBackend");

  @override
  final MediaSourceConfig config;

  final ItemMapper _map;
  final http.Client _http = http.Client();

  bool _connected = false;

  String? _musicSection;

  @override
  String get sourceId => config.sourceId;

  @override
  bool get isConnected => _connected;

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
    transcoding: false,
    playlists: false,
    favorites: false,
    playbackReporting: true,
    instantMix: false,
    serverLyrics: false,
    search: true,
  );

  Uri _url(String path, [Map<String, String> params = const {}]) {
    final base = Uri.parse(config.baseUrl);
    final target = Uri.parse(path);
    return base.replace(
      pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), ...target.pathSegments],
      queryParameters: {...target.queryParameters, ...params, "X-Plex-Token": config.accessToken},
    );
  }

  Future<Map<String, dynamic>?> _get(String path, [Map<String, String> params = const {}]) async {
    try {
      final response = await _http.get(_url(path, params), headers: {"Accept": "application/json"});
      if (response.statusCode != 200) {
        _log.warning("$path failed: HTTP ${response.statusCode}");
        return null;
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return body["MediaContainer"] as Map<String, dynamic>?;
    } catch (e) {
      _log.warning("$path failed on ${config.name}: $e");
      return null;
    }
  }

  static List<Map<String, dynamic>> _list(dynamic value) =>
      value is List ? value.cast<Map<String, dynamic>>() : const [];

  static String? _stripKey(String? key) => key?.replaceFirst("/library/metadata/", "");

  @override
  Future<bool> ping() async {
    final container = await _get("/library/sections");
    final section = _list(container?["Directory"]).firstWhere(
      (d) => d["type"] == "artist" || d["type"] == "music",
      orElse: () => const {},
    );
    _musicSection = section["key"]?.toString();
    _connected = _musicSection != null;
    return _connected;
  }

  Future<String?> _section() async {
    if (_musicSection == null) await ping();
    return _musicSection;
  }

  BaseItemDto _track(Map<String, dynamic> m) {
    final part = _list(_list(m["Media"]).firstOrNull?["Part"]).firstOrNull;
    final item = _map.track(
      nativeId: m["ratingKey"].toString(),
      name: (m["title"] ?? "Unknown") as String,
      album: m["parentTitle"] as String?,
      albumNativeId: _stripKey(m["parentKey"] as String?),
      artist: m["grandparentTitle"] as String?,
      artistNativeId: _stripKey(m["grandparentKey"] as String?),
      indexNumber: m["index"] as int?,
      parentIndexNumber: m["parentIndex"] as int?,
      productionYear: m["year"] as int?,
      duration: m["duration"] == null ? null : Duration(milliseconds: m["duration"] as int),
      hasImage: m["thumb"] != null,
    );
    item.path = part?["key"] as String?;
    return item;
  }

  BaseItemDto _album(Map<String, dynamic> m) => _map.album(
    nativeId: m["ratingKey"].toString(),
    name: (m["title"] ?? "Unknown Album") as String,
    artist: m["parentTitle"] as String?,
    artistNativeId: _stripKey(m["parentKey"] as String?),
    productionYear: m["year"] as int?,
    trackCount: m["leafCount"] as int?,
    hasImage: m["thumb"] != null,
  );

  BaseItemDto _artist(Map<String, dynamic> m) => _map.artist(
    nativeId: m["ratingKey"].toString(),
    name: (m["title"] ?? "Unknown Artist") as String,
    hasImage: m["thumb"] != null,
  );

  BaseItemDto _playlist(Map<String, dynamic> m) => _map.playlist(
    nativeId: m["ratingKey"].toString(),
    name: (m["title"] ?? "Unknown Playlist") as String,
    trackCount: m["leafCount"] as int?,
    hasImage: m["composite"] != null || m["thumb"] != null,
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
  }) async {
    final items = await _getItems(
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
    return sortItemsByJellyfinKeys(items.toList(), sortBy, sortOrder);
  }

  Future<List<BaseItemDto>> _getItems({
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
    if (parentItem != null) return _children(parentItem);

    if (searchTerm != null && searchTerm.isNotEmpty) {
      final container = await _get("/library/all", {"type": "10", "query": searchTerm});
      return _list(container?["Metadata"]).map(_track).toList();
    }

    if (includeItemTypes == "Playlist") {
      final container = await _get("/playlists");
      return _list(container?["Metadata"]).where((m) => m["playlistType"] == "audio").map(_playlist).toList();
    }

    final section = await _section();
    if (section == null) return const [];

    if (includeItemTypes == "MusicArtist") {
      final container = await _get("/library/sections/$section/all");
      return _list(container?["Metadata"]).map(_artist).toList();
    }

    final sort = switch (sortBy) {
      final String s when s.contains("DateCreated") => "addedAt:desc",
      final String s when s.contains("PlayCount") => "viewCount:desc",
      _ => null,
    };
    final container = await _get("/library/sections/$section/albums", {if (sort case final s?) "sort": s});
    return _list(container?["Metadata"]).map(_album).toList();
  }

  Future<List<BaseItemDto>> _children(BaseItemDto parent) async {
    final nativeId = parent.id.nativeId;
    final container = switch (parent.type) {
      "Playlist" => await _get("/playlists/$nativeId/items"),
      _ => await _get("/library/metadata/$nativeId/children"),
    };
    final children = _list(container?["Metadata"]);
    if (parent.type == "MusicArtist") return children.map(_album).toList();
    return children.map(_track).toList();
  }

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
  Future<BaseItemDto?> getItemById(BaseItemId id) async {
    final container = await _get("/library/metadata/${id.nativeId}");
    final metadata = _list(container?["Metadata"]).firstOrNull;
    if (metadata == null) return null;
    return switch (metadata["type"]) {
      "album" => _album(metadata),
      "artist" => _artist(metadata),
      _ => _track(metadata),
    };
  }

  @override
  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) async {
    final part = item.path ?? (await getItemById(item.id))?.path;
    if (part == null) {
      throw StateError("Plex track '${item.name}' has no media part to stream.");
    }
    return PlayableSource(_url(part));
  }

  @override
  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) async {
    final source = await resolveStream(item, transcode: false);
    return PlayableSource(source.uri.replace(queryParameters: {...source.uri.queryParameters, "download": "1"}));
  }

  @override
  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) {
    if (item.imageId == null) return null;
    return _url("/library/metadata/${item.id.nativeId}/thumb");
  }

  @override
  Map<String, String> get imageHeaders => const {};

  @override
  Future<LyricDto?> getLyrics(BaseItemDto item) async => null;

  @override
  Future<void> setFavorite(BaseItemDto item, {required bool isFavorite}) async {}

  @override
  Future<void> reportPlaybackStart(BaseItemDto item, {String? playSessionId}) =>
      _timeline(item, "playing", Duration.zero);

  @override
  Future<void> reportPlaybackProgress(
    BaseItemDto item, {
    required Duration position,
    required bool isPaused,
    String? playSessionId,
  }) => _timeline(item, isPaused ? "paused" : "playing", position);

  @override
  Future<void> reportPlaybackStopped(BaseItemDto item, {required Duration position, String? playSessionId}) =>
      _timeline(item, "stopped", position);

  Future<void> _timeline(BaseItemDto item, String state, Duration position) async {
    await _get("/:/timeline", {
      "ratingKey": item.id.nativeId,
      "state": state,
      "time": "${position.inMilliseconds}",
      "duration": "${item.runTimeTicksDuration()?.inMilliseconds ?? 0}",
    });
  }

  @override
  Future<void> logout() async {
    _connected = false;
    _http.close();
  }
}
