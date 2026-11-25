import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/item_sorter.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/hifi/dsd/byte_source.dart';
import 'package:diapason/services/hifi/dsd/dsd_container.dart';
import 'package:diapason/services/hifi/dsd/sacd.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

class LocalBackend implements MediaBackend {
  LocalBackend(this.config) : _map = ItemMapper(config.sourceId);

  static final _log = Logger("LocalBackend");
  static const _audioExtensions = {".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav", ".wma", ".alac", ".aiff"};

  /// DSD files and SACD images, read with the app's own parsers (see `lib/services/hifi`).
  static const _dsdExtensions = {".dsf", ".dff", ".iso"};

  @override
  final MediaSourceConfig config;

  final ItemMapper _map;

  final List<BaseItemDto> _tracks = [];
  final List<BaseItemDto> _albums = [];
  final List<BaseItemDto> _artists = [];

  final Map<String, String> _paths = {};

  bool _scanned = false;

  @override
  String get sourceId => config.sourceId;

  @override
  bool get isConnected => _scanned;

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(
    transcoding: false,
    playlists: false,
    favorites: false,
    playbackReporting: false,
    instantMix: false,
    serverLyrics: true,
    search: true,
  );

  @override
  Future<bool> ping() async {
    if (config.localPath.isEmpty) return false;
    if (!Directory(config.localPath).existsSync()) return false;
    if (!_scanned) await scan();
    return true;
  }

  /// The file behind a scanned track (used by the tag editor).
  String? pathFor(BaseItemId id) => _paths[id.nativeId];

  static String _idFor(String path) => sha1.convert(path.codeUnits).toString().substring(0, 16);

  Future<void> scan() async {
    final root = Directory(config.localPath);
    if (!root.existsSync()) {
      _log.warning("Local source '${config.name}' points at a missing folder: ${config.localPath}");
      return;
    }

    _tracks.clear();
    _albums.clear();
    _artists.clear();
    _paths.clear();

    final albumsSeen = <String, _AlbumAccumulator>{};
    final artistsSeen = <String, String>{};

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final extension = p.extension(entity.path).toLowerCase();
      if (_dsdExtensions.contains(extension)) {
        _scanDsd(entity, extension, albumsSeen);
        continue;
      }
      if (!_audioExtensions.contains(extension)) continue;

      try {
        final metadata = readMetadata(entity, getImage: false);
        final path = entity.path;
        final trackId = _idFor(path);

        final tagged = metadata.title?.trim() ?? "";
        final title = tagged.isNotEmpty ? tagged : p.basenameWithoutExtension(path);
        final artist = metadata.artist?.trim();
        final albumName = metadata.album?.trim();

        final artistId = artist == null ? null : _idFor("artist:$artist");
        if (artist != null && artistId != null) artistsSeen[artistId] = artist;

        final albumId = albumName == null ? null : _idFor("album:${artist ?? ""}:$albumName");
        if (albumName != null && albumId != null) {
          albumsSeen
              .putIfAbsent(
                albumId,
                () => _AlbumAccumulator(name: albumName, artist: artist, artistId: artistId, year: metadata.year?.year),
              )
              .trackCount++;
        }

        _paths[trackId] = path;
        _tracks.add(
          _map.track(
            nativeId: trackId,
            name: title,
            album: albumName,
            albumNativeId: albumId,
            artist: artist,
            artistNativeId: artistId,
            indexNumber: metadata.trackNumber,
            parentIndexNumber: metadata.discNumber,
            productionYear: metadata.year?.year,
            duration: metadata.duration,
            container: p.extension(path).replaceFirst(".", ""),
          ),
        );
      } catch (e) {
        _log.fine("Skipping unreadable file ${entity.path}: $e");
      }
    }

    _albums.addAll(
      albumsSeen.entries.map(
        (e) => _map.album(
          nativeId: e.key,
          name: e.value.name,
          artist: e.value.artist,
          artistNativeId: e.value.artistId,
          productionYear: e.value.year,
          trackCount: e.value.trackCount,
        ),
      ),
    );
    _artists.addAll(artistsSeen.entries.map((e) => _map.artist(nativeId: e.key, name: e.value)));

    _scanned = true;
    _log.info("Scanned ${config.localPath}: ${_tracks.length} tracks, ${_albums.length} albums.");
  }

  /// A DSF/DFF file becomes a track named after its file (their tags are ID3 in DSF only, and not read here); a SACD
  /// image becomes an album of its stereo area's tracks. Files that do not parse are skipped.
  void _scanDsd(File file, String extension, Map<String, _AlbumAccumulator> albumsSeen) {
    final path = file.path;
    ByteSource? source;
    try {
      source = FileByteSource(path);
      if (extension != ".iso") {
        final info = tryParseDsd(source);
        if (info == null) return;
        final trackId = _idFor(path);
        _paths[trackId] = path;
        _tracks.add(
          _map.track(
            nativeId: trackId,
            name: p.basenameWithoutExtension(path),
            duration: info.duration,
            container: extension.substring(1),
            codec: info.dst ? "dst" : "dsd",
            sampleRate: info.sampleRate,
            bitDepth: 1,
            channels: info.channels,
          ),
        );
        return;
      }
      final image = SacdImage.open(source);
      final area = image.area;
      final albumName = area.album ?? p.basenameWithoutExtension(path);
      final albumId = _idFor("sacd:$path");
      albumsSeen
              .putIfAbsent(
                albumId,
                () => _AlbumAccumulator(name: albumName, artist: area.artist, artistId: null, year: null),
              )
              .trackCount +=
          area.tracks.length;
      for (final track in area.tracks) {
        final trackId = _idFor("$path#${track.number}");
        _paths[trackId] = "$path#sacd=${track.number}";
        _tracks.add(
          _map.track(
            nativeId: trackId,
            name: track.title ?? "Track ${track.number}",
            album: albumName,
            albumNativeId: albumId,
            artist: track.performer ?? area.artist,
            indexNumber: track.number,
            parentIndexNumber: area.discNumber,
            duration: track.duration,
            container: "iso",
            codec: track.encoding == SacdEncoding.dst ? "dst" : "dsd",
            sampleRate: dsd64Rate,
            bitDepth: 1,
            channels: 2,
          ),
        );
      }
    } catch (e) {
      _log.fine("Skipping $path: $e");
    } finally {
      source?.close();
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
    if (!_scanned) await scan();

    if (parentItem != null) {
      return switch (parentItem.type) {
        "MusicAlbum" => _tracks.where((t) => t.albumId == parentItem.id).toList(),
        "MusicArtist" => _albums.where((a) => a.parentId == parentItem.id).toList(),
        _ => const [],
      };
    }

    if (searchTerm != null && searchTerm.isNotEmpty) {
      final needle = searchTerm.toLowerCase();
      bool matches(BaseItemDto i) => (i.name ?? "").toLowerCase().contains(needle);
      return switch (includeItemTypes) {
        "MusicAlbum" => _albums.where(matches).toList(),
        "MusicArtist" => _artists.where(matches).toList(),
        "Audio" => _tracks.where(matches).toList(),
        _ => [..._albums.where(matches), ..._artists.where(matches), ..._tracks.where(matches)],
      };
    }

    return switch (includeItemTypes) {
      "MusicArtist" => List.of(_artists),
      "Audio" => List.of(_tracks),
      "Playlist" => const [],
      _ => List.of(_albums),
    };
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
  Future<void> deleteItem(BaseItemId id, {required bool isPlaylist}) {
    throw UnsupportedError("Deleting items is not supported by this source.");
  }

  @override
  Future<void> reorderPlaylist(BaseItemDto playlist, List<BaseItemId> orderedItemIds) {
    throw UnsupportedError("${config.name} does not support playlists.");
  }

  @override
  Future<BaseItemDto?> getItemById(BaseItemId id) async {
    if (!_scanned) await scan();
    for (final list in [_tracks, _albums, _artists]) {
      final match = list.where((i) => i.id == id).firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  @override
  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) async {
    final path = _paths[item.id.nativeId];
    if (path == null) throw StateError("No local file is known for '${item.name}'.");
    final sacd = path.indexOf("#sacd=");
    if (sacd >= 0) {
      // A track of a SACD image: the fragment names it (see `sacdTrackOf`).
      return PlayableSource(
        Uri.file(File(path.substring(0, sacd)).absolute.path).replace(fragment: path.substring(sacd + 1)),
        container: "iso",
      );
    }
    return PlayableSource(Uri.file(File(path).absolute.path));
  }

  @override
  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) =>
      resolveStream(item, transcode: false);

  @override
  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) => null;

  @override
  Map<String, String> get imageHeaders => const {};

  @override
  Future<LyricDto?> getLyrics(BaseItemDto item) async {
    final path = _paths[item.id.nativeId];
    if (path == null) return null;

    final lrc = File(p.setExtension(path, ".lrc"));
    if (lrc.existsSync()) {
      final parsed = parseLrc(await lrc.readAsString());
      if (parsed != null) return parsed;
    }
    return null;
  }

  @visibleForTesting
  static LyricDto? parseLrc(String content) => LrcParser.parse(content);

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
  Future<void> logout() async {
    _scanned = false;
    _tracks.clear();
    _albums.clear();
    _artists.clear();
    _paths.clear();
  }
}

class _AlbumAccumulator {
  _AlbumAccumulator({required this.name, this.artist, this.artistId, this.year});

  final String name;
  final String? artist;
  final String? artistId;
  final int? year;
  int trackCount = 0;
}
