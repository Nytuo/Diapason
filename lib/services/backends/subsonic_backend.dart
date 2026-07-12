import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/item_sorter.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class SubsonicBackend implements MediaBackend {
  SubsonicBackend(this.config) : _map = ItemMapper(config.sourceId);

  static final _log = Logger("SubsonicBackend");
  static const _apiVersion = "1.16.1";
  static const _client = "diapason";

  @override
  final MediaSourceConfig config;

  final ItemMapper _map;
  final http.Client _http = http.Client();

  late final String _salt = _randomSalt();
  bool _connected = false;

  @override
  String get sourceId => config.sourceId;

  @override
  bool get isConnected => _connected;

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

  static String _randomSalt() {
    final rng = Random.secure();
    return List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, "0")).join();
  }

  Uri _url(String endpoint, [Map<String, dynamic> params = const {}]) {
    final token = md5.convert(utf8.encode(config.password + _salt)).toString();
    final base = Uri.parse(config.baseUrl);
    return base.replace(
      pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), "rest", "$endpoint.view"],
      queryParameters: {
        "u": config.username,
        "t": token,
        "s": _salt,
        "v": _apiVersion,
        "c": _client,
        "f": "json",
        ...params,
      },
    );
  }

  Future<Map<String, dynamic>?> _probe(String endpoint, String id) => _get(endpoint, {"id": id}, true);

  Future<Map<String, dynamic>?> _get(
    String endpoint, [
    Map<String, dynamic> params = const {},
    bool quiet = false,
  ]) async {
    void complain(String message) => quiet ? _log.fine(message) : _log.warning(message);

    try {
      final response = await _http.get(_url(endpoint, params));
      if (response.statusCode != 200) {
        complain("$endpoint failed: HTTP ${response.statusCode}");
        return null;
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final envelope = body["subsonic-response"] as Map<String, dynamic>?;
      if (envelope == null || envelope["status"] != "ok") {
        complain("$endpoint returned ${envelope?["status"]}: ${envelope?["error"]}");
        return null;
      }
      return envelope;
    } catch (e) {
      complain("$endpoint failed on ${config.name}: $e");
      return null;
    }
  }

  @override
  Future<bool> ping() async {
    _connected = await _get("ping") != null;
    return _connected;
  }

  BaseItemDto _song(Map<String, dynamic> s) => _map.track(
    nativeId: s["id"].toString(),
    name: (s["title"] ?? "Unknown") as String,
    album: s["album"] as String?,
    albumNativeId: s["albumId"]?.toString(),
    artist: s["artist"] as String?,
    artistNativeId: s["artistId"]?.toString(),
    indexNumber: s["track"] as int?,
    parentIndexNumber: s["discNumber"] as int?,
    productionYear: s["year"] as int?,
    duration: ItemMapper.seconds(s["duration"] as num?),
    container: s["suffix"] as String?,
    codec: (s["contentType"] as String?)?.split("/").lastOrNull ?? s["suffix"] as String?,
    size: (s["size"] as num?)?.toInt(),
    bitrateKbps: (s["bitRate"] as num?)?.toInt(),
    sampleRate: (s["samplingRate"] as num?)?.toInt(),
    bitDepth: (s["bitDepth"] as num?)?.toInt(),
    channels: (s["channelCount"] as num?)?.toInt(),
    hasImage: s["coverArt"] != null,
    isFavorite: s["starred"] != null,
  );

  BaseItemDto _album(Map<String, dynamic> a) => _map.album(
    nativeId: a["id"].toString(),
    name: (a["name"] ?? a["album"] ?? "Unknown Album") as String,
    artist: a["artist"] as String?,
    artistNativeId: a["artistId"]?.toString(),
    productionYear: a["year"] as int?,
    trackCount: a["songCount"] as int?,
    duration: ItemMapper.seconds(a["duration"] as num?),
    hasImage: a["coverArt"] != null,
    isFavorite: a["starred"] != null,
  );

  BaseItemDto _artist(Map<String, dynamic> a) => _map.artist(
    nativeId: a["id"].toString(),
    name: (a["name"] ?? "Unknown Artist") as String,
    albumCount: a["albumCount"] as int?,
    hasImage: a["coverArt"] != null,
    isFavorite: a["starred"] != null,
  );

  BaseItemDto _genre(Map<String, dynamic> g) =>
      _map.genre(name: (g["value"] ?? "Unknown Genre") as String, albumCount: g["albumCount"] as int?);

  static List<Map<String, dynamic>> _list(dynamic value) => switch (value) {
    final List<dynamic> l => l.cast<Map<String, dynamic>>(),
    final Map<String, dynamic> m => [m],
    _ => const [],
  };

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
    if (!_connected && !await ping()) return const [];

    if (parentItem != null) return _children(parentItem, includeItemTypes);

    if (searchTerm != null && searchTerm.isNotEmpty) return _search(searchTerm, includeItemTypes, limit);

    final favoritesOnly = filters?.contains("IsFavorite") ?? false;
    if (favoritesOnly) return _starred(includeItemTypes);

    if (genreFilter != null) {
      return _byGenre(ItemMapper.genreName(genreFilter), includeItemTypes, limit, startIndex);
    }

    return switch (includeItemTypes) {
      "MusicArtist" => _list((await _get("getArtists"))?["artists"]?["index"])
          .expand((index) => _list(index["artist"]))
          .map(_artist)
          .toList(),
      "Playlist" => _list((await _get("getPlaylists"))?["playlists"]?["playlist"]).map(_playlist).toList(),
      "MusicGenre" => _list((await _get("getGenres"))?["genres"]?["genre"]).map(_genre).toList(),
      "Audio" => _allTracks(sortBy: sortBy, sortOrder: sortOrder, limit: limit, offset: startIndex),
      _ => _albumList(sortBy: sortBy, limit: limit, offset: startIndex),
    };
  }

  
  
  static const _trackListCap = 10000;

  
  
  List<BaseItemDto>? _trackList;

  
  
  
  
  
  
  
  
  
  
  
  Future<List<BaseItemDto>> _allTracks({String? sortBy, String? sortOrder, int? limit, int? offset}) async {
    final start = offset ?? 0;
    final size = limit ?? 100;

    if (sortBy?.contains("Random") ?? false) {
      final response = await _get("getRandomSongs", {"size": "$size"});
      return _list(response?["randomSongs"]?["song"]).map(_song).toList();
    }

    if (start == 0 || _trackList == null) {
      _trackList = await _fetchTrackList();
    }
    final tracks = _trackList!;

    
    
    if (tracks.length >= _trackListCap) {
      final response = await _get("search3", {
        "query": "",
        "songCount": "$size",
        "songOffset": "$start",
        "albumCount": "0",
        "artistCount": "0",
      });
      return _list(response?["searchResult3"]?["song"]).map(_song).toList();
    }

    final sorted = sortItemsByJellyfinKeys(tracks.toList(), sortBy, sortOrder);
    if (start >= sorted.length) return const [];
    return sorted.sublist(start, min(start + size, sorted.length));
  }

  Future<List<BaseItemDto>> _fetchTrackList() async {
    final response = await _get("search3", {
      "query": "",
      "songCount": "$_trackListCap",
      "songOffset": "0",
      "albumCount": "0",
      "artistCount": "0",
    });
    return _list(response?["searchResult3"]?["song"]).map(_song).toList();
  }

  Future<List<BaseItemDto>> _byGenre(String genre, String? includeItemTypes, int? limit, int? offset) async {
    if (includeItemTypes == "Audio") {
      final response = await _get("getSongsByGenre", {
        "genre": genre,
        "count": "${limit ?? 100}",
        if (offset != null) "offset": "$offset",
      });
      return _list(response?["songsByGenre"]?["song"]).map(_song).toList();
    }

    final response = await _get("getAlbumList2", {
      "type": "byGenre",
      "genre": genre,
      "size": "${limit ?? 500}",
      if (offset != null && includeItemTypes != "MusicArtist") "offset": "$offset",
    });
    final albums = _list(response?["albumList2"]?["album"]);

    if (includeItemTypes != "MusicArtist") return albums.map(_album).toList();

    final seen = <String>{};
    return albums
        .where((a) => a["artistId"] != null && seen.add(a["artistId"] as String))
        .map((a) => _map.artist(nativeId: a["artistId"] as String, name: (a["artist"] as String?) ?? "Unknown Artist"))
        .toList();
  }

  Future<List<BaseItemDto>> _albumList({String? sortBy, int? limit, int? offset}) async {
    final type = switch (sortBy) {
      final String s when s.contains("DateCreated") => "newest",
      final String s when s.contains("PlayCount") => "frequent",
      final String s when s.contains("DatePlayed") => "recent",
      final String s when s.contains("Random") => "random",
      _ => "alphabeticalByArtist",
    };
    final response = await _get("getAlbumList2", {
      "type": type,
      "size": "${limit ?? 500}",
      if (offset != null) "offset": "$offset",
    });
    return _list(response?["albumList2"]?["album"]).map(_album).toList();
  }

  Future<List<BaseItemDto>> _children(BaseItemDto parent, String? includeItemTypes) async {
    final nativeId = parent.id.nativeId;
    final wantsTracks = includeItemTypes == "Audio";

    switch (parent.type) {
      case "MusicAlbum":
        final response = await _get("getAlbum", {"id": nativeId});
        return _list(response?["album"]?["song"]).map(_song).toList();
      case "MusicArtist":
        final response = await _get("getArtist", {"id": nativeId});
        final albums = _list(response?["artist"]?["album"]);
        if (!wantsTracks) return albums.map(_album).toList();

        final tracks = await Future.wait(
          albums.map((album) async {
            final full = await _get("getAlbum", {"id": album["id"].toString()});
            return _list(full?["album"]?["song"]).map(_song).toList();
          }),
        );
        return tracks.expand((t) => t).toList();
      case "Playlist":
        final response = await _get("getPlaylist", {"id": nativeId});
        final entries = _list(response?["playlist"]?["entry"]);
        return entries.indexed.map((e) => _song(e.$2)..playlistItemId = "${e.$1}").toList();
      case "MusicGenre":
        return _byGenre(nativeId, includeItemTypes, null, null);
      default:
        return const [];
    }
  }

  Future<List<BaseItemDto>> _search(String query, String? types, int? limit) async {
    final size = "${limit ?? 50}";
    final response = await _get("search3", {
      "query": query,
      "songCount": size,
      "albumCount": size,
      "artistCount": size,
    });
    final result = response?["searchResult3"] as Map<String, dynamic>?;
    if (result == null) return const [];

    return switch (types) {
      "Audio" => _list(result["song"]).map(_song).toList(),
      "MusicAlbum" => _list(result["album"]).map(_album).toList(),
      "MusicArtist" => _list(result["artist"]).map(_artist).toList(),
      _ => [
        ..._list(result["album"]).map(_album),
        ..._list(result["artist"]).map(_artist),
        ..._list(result["song"]).map(_song),
      ],
    };
  }

  Future<List<BaseItemDto>> _starred(String? types) async {
    final starred = (await _get("getStarred2"))?["starred2"] as Map<String, dynamic>?;
    if (starred == null) return const [];
    return switch (types) {
      "MusicAlbum" => _list(starred["album"]).map(_album).toList(),
      "MusicArtist" => _list(starred["artist"]).map(_artist).toList(),
      _ => _list(starred["song"]).map(_song).toList(),
    };
  }

  BaseItemDto _playlist(Map<String, dynamic> p) => _map.playlist(
    nativeId: p["id"].toString(),
    name: (p["name"] ?? "Unknown Playlist") as String,
    trackCount: p["songCount"] as int?,
    duration: ItemMapper.seconds(p["duration"] as num?),
    hasImage: p["coverArt"] != null,
  );

  @override
  Future<List<BaseItemDto>> getRadioStations() async {
    if (!_connected && !await ping()) return const [];

    final response = await _get("getInternetRadioStations");
    return _list(response?["internetRadioStations"]?["internetRadioStation"]).map((station) {
      final item = _map.track(
        nativeId: station["id"].toString(),
        name: (station["name"] ?? "Unknown Station") as String,
        artist: "Internet Radio",
      );
      item.path = station["streamUrl"] as String?;
      return item;
    }).where((item) => (item.path ?? "").isNotEmpty).toList();
  }

  @override
  @override
  Future<BaseItemDto?> getItemById(BaseItemId id) async {
    final nativeId = id.nativeId;

    final song = (await _probe("getSong", nativeId))?["song"] as Map<String, dynamic>?;
    if (song != null) return _song(song);

    final album = (await _probe("getAlbum", nativeId))?["album"] as Map<String, dynamic>?;
    if (album != null) return _album(album);

    final artist = (await _probe("getArtist", nativeId))?["artist"] as Map<String, dynamic>?;
    if (artist != null) return _artist(artist);

    final playlist = (await _probe("getPlaylist", nativeId))?["playlist"] as Map<String, dynamic>?;
    if (playlist != null) return _playlist(playlist);

    _log.fine("No song, album, artist or playlist on ${config.name} with id '$nativeId'.");
    return null;
  }

  @override
  Future<List<BaseItemDto>> getInstantMix(BaseItemDto item, {int? limit}) async {
    final response = await _get("getSimilarSongs2", {
      "id": item.id.nativeId,
      "count": "${limit ?? 50}",
    });
    return _list(response?["similarSongs2"]?["song"]).map(_song).toList();
  }

  @override
  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) async {
    if (item.path case final stationUrl? when stationUrl.startsWith("http")) {
      return PlayableSource(Uri.parse(stationUrl));
    }

    final kbps = FinampSettingsHelper.finampSettings.transcodeBitrate ~/ 1000;
    return PlayableSource(
      _url("stream", {
        "id": item.id.nativeId,
        if (transcode) ...{"format": "mp3", "maxBitRate": "$kbps"} else "format": "raw",
      }),
    );
  }

  @override
  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) async {
    final original = transcodingProfile == null || transcodingProfile.codec == FinampTranscodingCodec.original;
    return PlayableSource(
      _url("download", {"id": item.id.nativeId, if (original) "format": "raw"}),
    );
  }

  @override
  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) {
    if (item.imageId == null) return null;
    final size = maxWidth ?? maxHeight;
    return _url("getCoverArt", {"id": item.id.nativeId, if (size != null) "size": "$size"});
  }

  @override
  Map<String, String> get imageHeaders => const {};

  @override
  Future<LyricDto?> getLyrics(BaseItemDto item) async {
    final structured = await _get("getLyricsBySongId", {"id": item.id.nativeId});
    final lyricsList = _list(structured?["lyricsList"]?["structuredLyrics"]).firstOrNull;
    final lines = _list(lyricsList?["line"]);
    if (lines.isNotEmpty) {
      return LyricDto(
        lyrics: lines
            .map(
              (l) => LyricLine(
                text: (l["value"] ?? "") as String,
                start: l["start"] == null ? null : (l["start"] as num).round() * 10000,
              ),
            )
            .toList(),
      );
    }

    final plain = (await _get("getLyrics", {"id": item.id.nativeId}))?["lyrics"]?["value"] as String?;
    if (plain == null || plain.trim().isEmpty) return null;
    return LyricDto(lyrics: plain.split("\n").map((t) => LyricLine(text: t)).toList());
  }

  @override
  Future<void> setFavorite(BaseItemDto item, {required bool isFavorite}) async {
    await _get(isFavorite ? "star" : "unstar", {"id": item.id.nativeId});
  }

  @override
  Future<BaseItemDto> createPlaylist(String name, {List<BaseItemId> itemIds = const [], bool isPublic = true}) async {
    final response = await _get("createPlaylist", {
      "name": name,
      if (itemIds.isNotEmpty) "songId": itemIds.map((id) => id.nativeId).toList(),
    });
    final playlist = response?["playlist"] as Map<String, dynamic>?;
    if (playlist == null) {
      throw Exception("${config.name} did not return the playlist it just created.");
    }
    return _playlist(playlist);
  }

  @override
  Future<void> addToPlaylist(BaseItemDto playlist, List<BaseItemId> itemIds) async {
    await _get("updatePlaylist", {
      "playlistId": playlist.id.nativeId,
      "songIdToAdd": itemIds.map((id) => id.nativeId).toList(),
    });
  }

  @override
  Future<void> removeFromPlaylist(BaseItemDto playlist, List<String> playlistItemIds) async {
    await _get("updatePlaylist", {
      "playlistId": playlist.id.nativeId,
      "songIndexToRemove": playlistItemIds,
    });
  }

  @override
  Future<void> updatePlaylistMetadata(BaseItemDto playlist, {String? name, bool? isPublic}) async {
    await _get("updatePlaylist", {
      "playlistId": playlist.id.nativeId,
      if (name != null) "name": name,
      if (isPublic != null) "public": "$isPublic",
    });
  }

  @override
  Future<void> reorderPlaylist(BaseItemDto playlist, List<BaseItemId> orderedItemIds) async {
    final current = await _children(playlist, "Audio");
    await _get("updatePlaylist", {
      "playlistId": playlist.id.nativeId,
      if (current.isNotEmpty) "songIndexToRemove": List.generate(current.length, (i) => "$i"),
      "songIdToAdd": orderedItemIds.map((id) => id.nativeId).toList(),
    });
  }

  @override
  Future<void> reportPlaybackStart(BaseItemDto item, {String? playSessionId}) async {
    await _get("scrobble", {"id": item.id.nativeId, "submission": "false"});
  }

  @override
  Future<void> reportPlaybackProgress(
    BaseItemDto item, {
    required Duration position,
    required bool isPaused,
    String? playSessionId,
  }) async {}

  @override
  Future<void> reportPlaybackStopped(BaseItemDto item, {required Duration position, String? playSessionId}) async {
    await _get("scrobble", {"id": item.id.nativeId, "submission": "true"});
  }

  @override
  Future<void> logout() async {
    _connected = false;
    _http.close();
  }
}
