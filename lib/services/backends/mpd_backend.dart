import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/mpd/mpd_client.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

class MpdBackend implements MediaBackend {
  MpdBackend(this.config) {
    _map = ItemMapper(config.sourceId);
    final parts = config.publicAddress.split(":");
    _host = parts.isNotEmpty && parts.first.isNotEmpty ? parts.first : "localhost";
    _port = parts.length > 1 ? int.tryParse(parts[1]) ?? 6600 : 6600;
  }

  @override
  final MediaSourceConfig config;

  static final _log = Logger("MpdBackend");

  late final ItemMapper _map;
  late final String _host;
  late final int _port;

  MpdClient? _client;
  String? _musicDir;

  @override
  String get sourceId => config.sourceId;

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(search: true);

  @override
  bool get isConnected => _client?.isConnected ?? false;

  Future<MpdClient?> _connected() async {
    if (_client != null && _client!.isConnected) return _client;
    try {
      final client = MpdClient(host: _host, port: _port, password: config.password.isEmpty ? null : config.password);
      await client.connect();
      _client = client;
      _musicDir = config.localPath.isNotEmpty ? config.localPath : await _queryMusicDir(client);
      return client;
    } catch (e) {
      _log.warning("MPD connect to $_host:$_port failed: $e");
      _client = null;
      return null;
    }
  }

  Future<String?> _queryMusicDir(MpdClient client) async {
    try {
      final lines = await client.command("config");
      return MpdClient.single(lines)["music_directory"];
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> ping() async => (await _connected()) != null;

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
    final client = await _connected();
    if (client == null) return const [];

    if (parentItem != null) return _children(client, parentItem);
    if (searchTerm != null && searchTerm.isNotEmpty) return _search(client, searchTerm, includeItemTypes);
    if (genreFilter != null) return _albumsWhere(client, "genre", ItemMapper.genreName(genreFilter));

    switch (includeItemTypes) {
      case "MusicArtist":
        final lines = await client.command("list albumartist");
        return lines
            .where((l) => l.key == "AlbumArtist" && l.value.isNotEmpty)
            .map((l) => _map.artist(nativeId: l.value, name: l.value))
            .toList();
      case "MusicGenre":
        final lines = await client.command("list genre");
        return lines.where((l) => l.key == "Genre" && l.value.isNotEmpty).map((l) => _map.genre(name: l.value)).toList();
      case "Audio":
        return _allTracks(client, limit: limit, offset: startIndex);
      case "MusicAlbum":
      default:
        return _albums(client);
    }
  }

  Future<List<BaseItemDto>> _albums(MpdClient client) async {
    final lines = await client.command("list album group albumartist");
    final out = <BaseItemDto>[];
    String? artist;
    for (final l in lines) {
      if (l.key == "AlbumArtist") {
        artist = l.value;
      } else if (l.key == "Album" && l.value.isNotEmpty) {
        out.add(_map.album(nativeId: l.value, name: l.value, artist: artist, artistNativeId: artist));
      }
    }
    return out;
  }

  Future<List<BaseItemDto>> _albumsWhere(MpdClient client, String tag, String value) async {
    final lines = await client.command("list album $tag ${MpdClient.quote(value)}");
    return lines
        .where((l) => l.key == "Album" && l.value.isNotEmpty)
        .map((l) => _map.album(nativeId: l.value, name: l.value))
        .toList();
  }

  Future<List<BaseItemDto>> _children(MpdClient client, BaseItemDto parent) async {
    final type = BaseItemDtoType.fromItem(parent);
    switch (type) {
      case BaseItemDtoType.album:
      case BaseItemDtoType.playlist:
        final lines = await client.command("find album ${MpdClient.quote(parent.id.nativeId)}");
        return _tracksFrom(lines, parent);
      case BaseItemDtoType.artist:
        return _albumsWhere(client, "albumartist", parent.id.nativeId);
      case BaseItemDtoType.genre:
        return _albumsWhere(client, "genre", parent.id.nativeId);
      default:
        return const [];
    }
  }

  Future<List<BaseItemDto>> _search(MpdClient client, String term, String? includeItemTypes) async {
    if (includeItemTypes == "MusicArtist") {
      final lines = await client.command("list albumartist albumartist ${MpdClient.quote(term)}");
      return lines.where((l) => l.key == "AlbumArtist" && l.value.isNotEmpty).map((l) => _map.artist(nativeId: l.value, name: l.value)).toList();
    }
    if (includeItemTypes == "MusicAlbum") {
      return _albumsWhere(client, "album", term);
    }
    final lines = await client.command("search any ${MpdClient.quote(term)}");
    return _tracksFrom(lines, null);
  }

  Future<List<BaseItemDto>> _allTracks(MpdClient client, {int? limit, int? offset}) async {
    final lines = await client.command("listallinfo");
    final all = _tracksFrom(lines, null);
    final start = offset ?? 0;
    if (start >= all.length) return const [];
    final end = limit == null ? all.length : (start + limit).clamp(0, all.length);
    return all.sublist(start, end);
  }

  List<BaseItemDto> _tracksFrom(List<MapEntry<String, String>> lines, BaseItemDto? album) {
    final songs = MpdClient.group(lines, {"file"});
    var index = 0;
    return songs.where((m) => (m["file"] ?? "").isNotEmpty).map((m) {
      index++;
      final secs = double.tryParse(m["duration"] ?? m["Time"] ?? "");
      return _map.track(
        nativeId: m["file"]!,
        name: m["Title"] ?? p.basename(m["file"]!),
        album: m["Album"] ?? album?.name,
        albumNativeId: m["Album"] ?? album?.id.nativeId,
        artist: m["Artist"] ?? m["AlbumArtist"],
        artistNativeId: m["AlbumArtist"] ?? m["Artist"],
        indexNumber: int.tryParse(m["Track"] ?? "") ?? index,
        duration: secs == null ? null : Duration(milliseconds: (secs * 1000).round()),
        container: p.extension(m["file"]!).replaceFirst(".", ""),
      );
    }).toList();
  }

  @override
  Future<BaseItemDto?> getItemById(BaseItemId id) async {
    final client = await _connected();
    if (client == null) return null;
    final lines = await client.command("find file ${MpdClient.quote(id.nativeId)}");
    final tracks = _tracksFrom(lines, null);
    return tracks.isEmpty ? null : tracks.first;
  }

  @override
  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) async {
    await _connected();
    final dir = _musicDir;
    final file = item.id.nativeId;
    if (dir == null) {
      throw StateError("MPD music directory unknown; set it in the source settings to enable playback.");
    }
    return PlayableSource(Uri.file(p.join(dir, file)), container: item.container);
  }

  @override
  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) =>
      resolveStream(item, transcode: false);

  @override
  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) => null;

  @override
  Map<String, String> get imageHeaders => const {};

  @override
  Future<List<BaseItemDto>> getInstantMix(BaseItemDto item, {int? limit}) async => const [];

  @override
  Future<List<BaseItemDto>> getRadioStations() async => const [];

  @override
  Future<LyricDto?> getLyrics(BaseItemDto item) async => null;

  @override
  Future<void> setFavorite(BaseItemDto item, {required bool isFavorite}) async {}

  @override
  Future<void> reportPlaybackStart(BaseItemDto item, {String? playSessionId}) async {}

  @override
  Future<void> reportPlaybackProgress(BaseItemDto item, {required Duration position, required bool isPaused, String? playSessionId}) async {}

  @override
  Future<void> reportPlaybackStopped(BaseItemDto item, {required Duration position, String? playSessionId}) async {}

  @override
  Future<BaseItemDto> createPlaylist(String name, {List<BaseItemId> itemIds = const [], bool isPublic = true}) =>
      throw UnsupportedError("MPD does not support creating playlists here.");

  @override
  Future<void> addToPlaylist(BaseItemDto playlist, List<BaseItemId> itemIds) =>
      throw UnsupportedError("MPD does not support playlists here.");

  @override
  Future<void> removeFromPlaylist(BaseItemDto playlist, List<String> playlistItemIds) =>
      throw UnsupportedError("MPD does not support playlists here.");

  @override
  Future<void> updatePlaylistMetadata(BaseItemDto playlist, {String? name, bool? isPublic}) =>
      throw UnsupportedError("MPD does not support playlists here.");

  @override
  Future<void> reorderPlaylist(BaseItemDto playlist, List<BaseItemId> orderedItemIds) =>
      throw UnsupportedError("MPD does not support playlists here.");

  @override
  Future<void> logout() async {
    await _client?.close();
    _client = null;
  }
}
