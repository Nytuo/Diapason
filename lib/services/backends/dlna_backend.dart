import 'dart:math';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/item_sorter.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/dlna/dlna_client.dart';
import 'package:diapason/services/dlna/dlna_protocol.dart';
import 'package:logging/logging.dart';

/// The library views a DLNA server may offer, found by class (with `Search`)
/// or by the title of its containers (MiniDLNA's "Music > Album", Jellyfin's
/// "Music > Albums", Serviio's "Audio > Albums", ...).
enum DlnaView { albums, artists, genres, playlists, tracks, folders }

/// A UPnP AV / DLNA media server (MiniDLNA/ReadyMedia, Gerbera, Serviio,
/// Universal Media Server, Jellyfin's DLNA plugin, NAS servers...) read
/// through its ContentDirectory.
///
/// [MediaSourceConfig.publicAddress] holds the device description URL (or a
/// host:port, where the usual description paths are tried);
/// [MediaSourceConfig.userId] its UDN. There is no sign-in: who may read the
/// server is the server's own setting.
class DlnaBackend implements MediaBackend {
  DlnaBackend(this.config, {DlnaClient? client}) : _map = ItemMapper(config.sourceId), _client = client ?? DlnaClient();

  static final _log = Logger("DlnaBackend");

  @override
  final MediaSourceConfig config;

  final ItemMapper _map;
  final DlnaClient _client;

  static const _page = 200;

  /// Most entries one listing is read for, and most containers a walk
  /// opens for the tracks below an artist or genre.
  static const _listCap = 20000;
  static const _walkContainers = 60;
  static const _walkTrackCap = 3000;

  DlnaDevice? _device;
  Set<String> _searchCaps = const {};
  final Map<DlnaView, String?> _viewIds = {};
  bool _viewsResolved = false;
  final Map<DlnaView, List<BaseItemDto>> _lists = {};

  /// Stream URLs seen in listings, by object id, so playback needn't ask again.
  final Map<String, DidlResource> _resources = {};

  @override
  String get sourceId => config.sourceId;

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(search: true);

  @override
  bool get isConnected => _device != null;

  DlnaDevice? get device => _device;

  bool get _searchesByClass => _searchCaps.contains("*") || _searchCaps.contains("upnp:class");
  bool get _searchesByTitle => _searchCaps.contains("*") || _searchCaps.contains("dc:title");

  Future<Uri?> _control() async {
    if (_device != null) return _device!.controlUrl;
    try {
      final device = await _client.probe(config.publicAddress);
      _device = device;
      try {
        _searchCaps = await _client.searchCapabilities(device.controlUrl);
      } catch (e) {
        _log.fine("${config.name}: GetSearchCapabilities failed, browsing only: $e");
        _searchCaps = const {};
      }
      _log.info("Connected to ${device.friendlyName} (${device.product}); search caps: $_searchCaps");
      return device.controlUrl;
    } catch (e) {
      _log.warning("DLNA server ${config.name} at ${config.publicAddress} unreachable: $e");
      return null;
    }
  }

  @override
  Future<bool> ping() async {
    final control = await _control();
    if (control == null) return false;
    try {
      await _client.browse(control, dlnaRootId, metadata: true, count: 1);
      return true;
    } catch (e) {
      _log.warning("DLNA ping of ${config.name} failed: $e");
      _device = null;
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Listing helpers

  Future<List<DidlObject>> _browseAll(Uri control, String id, {int cap = _listCap}) async {
    final out = <DidlObject>[];
    var start = 0;
    while (out.length < cap) {
      final page = await _client.browse(control, id, start: start, count: min(_page, cap - out.length));
      out.addAll(page.objects);
      start += page.numberReturned;
      if (page.numberReturned == 0 || (page.totalMatches > 0 && start >= page.totalMatches)) break;
    }
    return out;
  }

  Future<List<DidlObject>> _searchAll(Uri control, String criteria, {int cap = _listCap}) async {
    final out = <DidlObject>[];
    var start = 0;
    while (out.length < cap) {
      final page = await _client.search(
        control,
        dlnaRootId,
        criteria,
        start: start,
        count: min(_page, cap - out.length),
      );
      out.addAll(page.objects);
      start += page.numberReturned;
      if (page.numberReturned == 0 || (page.totalMatches > 0 && start >= page.totalMatches)) break;
    }
    return out;
  }

  static String _normalizeTitle(String title) {
    var t = title.trim().toLowerCase().replaceAll(RegExp(r"^[-\s]+|[-\s]+$"), "");
    for (final prefix in const ["by ", "all ", "par ", "tous les ", "toutes les ", "tous ", "toutes "]) {
      if (t.startsWith(prefix)) t = t.substring(prefix.length).trim();
    }
    return t;
  }

  static const _musicRootNames = {"music", "audio", "musique", "musik", "música", "musica", "muziek"};
  static const _nonMusicRootNames = {
    "video",
    "videos",
    "vidéo",
    "vidéos",
    "pictures",
    "photos",
    "images",
    "picture",
    "photo",
    "movies",
    "films",
    "tv shows",
    "séries",
    "series",
  };

  /// Container titles each view goes by, best first.
  static const Map<DlnaView, List<String>> viewNames = {
    DlnaView.albums: ["albums", "album"],
    DlnaView.artists: ["album artists", "album artist", "artists", "artist", "artistes", "artiste", "interprètes"],
    DlnaView.genres: ["genres", "genre"],
    DlnaView.playlists: ["playlists", "playlist", "listes de lecture", "liste de lecture"],
    DlnaView.tracks: [
      "tracks",
      "songs",
      "music",
      "titres",
      "morceaux",
      "chansons",
      "musique",
      "audio",
      "track",
      "song",
    ],
    DlnaView.folders: ["folders", "folder", "browse folders", "directories", "directory", "dossiers", "dossier"],
  };

  /// Picks, among containers, the one for each view. Exposed for tests.
  static Map<DlnaView, String> matchViews(List<DidlObject> containers) {
    final out = <DlnaView, String>{};
    for (final view in DlnaView.values) {
      for (final name in viewNames[view]!) {
        final hit = containers.where((c) => c.isContainer && _normalizeTitle(c.title) == name).firstOrNull;
        if (hit != null) {
          out[view] = hit.id;
          break;
        }
      }
    }
    return out;
  }

  Future<void> _resolveViews(Uri control) async {
    if (_viewsResolved) return;
    final root = (await _browseAll(control, dlnaRootId, cap: 200)).where((o) => o.isContainer).toList();
    final musicRoot = root.where((c) => _musicRootNames.contains(_normalizeTitle(c.title))).firstOrNull;
    final found = <DlnaView, String>{};
    if (musicRoot != null) {
      final inside = (await _browseAll(control, musicRoot.id, cap: 200)).where((o) => o.isContainer).toList();
      found.addAll(matchViews(inside));
    }
    final rootMatches = matchViews(root.where((c) => c.id != musicRoot?.id).toList());
    for (final e in rootMatches.entries) {
      found.putIfAbsent(e.key, () => e.value);
    }
    _viewIds
      ..clear()
      ..addAll(found);
    _viewsResolved = true;
    _log.info("${config.name}: views found by title: ${found.keys.map((v) => v.name).join(", ")}");
  }

  Future<String?> _viewId(Uri control, DlnaView view) async {
    await _resolveViews(control);
    return _viewIds[view];
  }

  // -------------------------------------------------------------------------
  // Mapping

  BaseItemDto _containerItem(DidlObject o, {String? forceType}) {
    final type =
        forceType ??
        (o.isMusicAlbum
            ? "MusicAlbum"
            : o.isMusicArtist
            ? "MusicArtist"
            : o.isMusicGenre
            ? "MusicGenre"
            : o.isPlaylist
            ? "Playlist"
            : "Folder");
    final art = o.artUri;
    final BaseItemDto item = switch (type) {
      "MusicAlbum" => _map.album(
        nativeId: o.id,
        name: o.title,
        artist: o.albumArtist ?? o.displayArtist,
        productionYear: o.year,
        trackCount: o.childCount,
      ),
      "MusicArtist" => _map.artist(nativeId: o.id, name: o.title, albumCount: o.childCount),
      "Playlist" => _map.playlist(nativeId: o.id, name: o.title, trackCount: o.childCount),
      _ => BaseItemDto(id: _map.id(o.id), name: o.title, type: type, childCount: o.childCount),
    };
    if (art != null) item.imageTags = {"Primary": art.toString()};
    return item;
  }

  BaseItemDto? _trackItem(DidlObject o) {
    if (!o.isAudioItem) return null;
    final res = o.bestAudioResource;
    if (res == null) return null;
    _resources[o.id] = res;
    final art = o.artUri;
    final item = _map.track(
      nativeId: o.id,
      name: o.title.isEmpty ? res.uri.pathSegments.lastOrNull ?? o.id : o.title,
      album: o.album,
      albumNativeId: o.album == null || o.parentId.isEmpty ? null : o.parentId,
      artist: o.displayArtist,
      indexNumber: o.trackNumber,
      parentIndexNumber: o.discNumber,
      productionYear: o.year,
      duration: res.duration,
      container: res.container,
      size: res.size,
      bitrateKbps: res.bitrate == null ? null : (res.bitrate! * 8 / 1000).round(),
      sampleRate: res.sampleFrequency,
      bitDepth: res.bitsPerSample,
      channels: res.channels,
    );
    if (art != null) item.imageTags = {"Primary": art.toString()};
    if (o.genres.isNotEmpty) item.genres = o.genres;
    return item;
  }

  /// Containers and tracks of a listing, in order. [containerType] forces
  /// the type of generic containers (e.g. inside an "Albums" view).
  List<BaseItemDto> _mapListing(List<DidlObject> objects, {String? containerType, bool skipNonMusic = false}) {
    final out = <BaseItemDto>[];
    for (final o in objects) {
      if (o.isContainer) {
        if (o.isNonMusicContainer) continue;
        if (skipNonMusic && _nonMusicRootNames.contains(_normalizeTitle(o.title))) continue;
        final classed = o.isMusicAlbum || o.isMusicArtist || o.isMusicGenre || o.isPlaylist;
        out.add(_containerItem(o, forceType: classed ? null : containerType));
      } else {
        final track = _trackItem(o);
        if (track != null) out.add(track);
      }
    }
    return out;
  }

  static bool _isPlaceholder(String title) {
    final t = title.trim();
    return t.startsWith("-") && t.endsWith("-") && t.length > 2;
  }

  // -------------------------------------------------------------------------
  // MediaBackend

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
    final control = await _control();
    if (control == null) return const [];

    if (parentItem != null) return _children(control, parentItem, includeItemTypes);
    if (searchTerm != null && searchTerm.trim().isNotEmpty) {
      return _search(control, searchTerm.trim(), includeItemTypes, limit);
    }
    // No favourites on DLNA.
    if ((isFavorite ?? false) || (filters?.contains("IsFavorite") ?? false)) return const [];
    if (genreFilter != null) {
      final genre = BaseItemDto(id: genreFilter, name: genreFilter.nativeId, type: "MusicGenre");
      return _children(control, genre, includeItemTypes);
    }

    final types = includeItemTypes ?? "";
    final DlnaView? view = types.contains("MusicAlbum")
        ? DlnaView.albums
        : types.contains("MusicArtist")
        ? DlnaView.artists
        : types.contains("MusicGenre")
        ? DlnaView.genres
        : types.contains("Playlist")
        ? DlnaView.playlists
        : types.contains("Audio")
        ? DlnaView.tracks
        : null;

    if (view == null) {
      // The folder view: the server's own top level.
      return _mapListing(await _browseAll(control, dlnaRootId, cap: 2000), skipNonMusic: true);
    }
    if (view == DlnaView.tracks) return _tracks(control, startIndex ?? 0, limit ?? 100);

    final start = startIndex ?? 0;
    if (start == 0 || !_lists.containsKey(view)) {
      _lists[view] = await _listView(control, view);
    }
    final sorted = sortItemsByJellyfinKeys(_lists[view]!.toList(), sortBy ?? "SortName", sortOrder);
    if (start >= sorted.length) return const [];
    return sorted.sublist(start, limit == null ? sorted.length : min(start + limit, sorted.length));
  }

  static const _classOf = {
    DlnaView.albums: ("object.container.album.musicAlbum", "MusicAlbum"),
    DlnaView.artists: ("object.container.person.musicArtist", "MusicArtist"),
    DlnaView.genres: ("object.container.genre.musicGenre", "MusicGenre"),
    DlnaView.playlists: ("object.container.playlistContainer", "Playlist"),
  };

  Future<List<BaseItemDto>> _listView(Uri control, DlnaView view) async {
    final (upnpClass, type) = _classOf[view]!;
    if (_searchesByClass) {
      try {
        final found = await _searchAll(control, searchCriteria(upnpClass));
        final items = _dedupe(found.where((o) => o.isContainer).map((o) => _containerItem(o, forceType: type)));
        if (items.isNotEmpty) return items;
      } on DlnaFault catch (e) {
        _log.info("${config.name}: Search for $upnpClass refused ($e); browsing instead.");
      }
    }
    final id = await _viewId(control, view);
    if (id == null) return const [];
    final objects = await _browseAll(control, id);
    return _dedupe(
      objects.where((o) => o.isContainer && !_isPlaceholder(o.title)).map((o) => _containerItem(o, forceType: type)),
    );
  }

  /// Servers list the same name under several ids (one album per artist
  /// view...): keep the first of each name and artist.
  static List<BaseItemDto> _dedupe(Iterable<BaseItemDto> items) {
    final seen = <String>{};
    return items.where((i) => seen.add("${i.type}\u{1f}${i.name}\u{1f}${i.albumArtist ?? ""}")).toList();
  }

  Future<List<BaseItemDto>> _tracks(Uri control, int start, int count) async {
    if (_searchesByClass) {
      try {
        final page = await _client.search(
          control,
          dlnaRootId,
          searchCriteria("object.item.audioItem"),
          start: start,
          count: count,
        );
        if (page.objects.isNotEmpty || start > 0) return page.objects.map(_trackItem).nonNulls.toList();
      } on DlnaFault catch (e) {
        _log.info("${config.name}: Search for tracks refused ($e); browsing instead.");
      }
    }
    final id = await _viewId(control, DlnaView.tracks);
    if (id == null) return const [];
    final page = await _client.browse(control, id, start: start, count: count);
    return page.objects.map(_trackItem).nonNulls.toList();
  }

  Future<List<BaseItemDto>> _children(Uri control, BaseItemDto parent, String? includeItemTypes) async {
    final id = parent.id.nativeId;
    final wantsTracks = includeItemTypes?.contains("Audio") ?? false;
    final objects = await _browseAll(control, id, cap: 5000);

    switch (BaseItemDtoType.fromItem(parent)) {
      case BaseItemDtoType.album:
        // Tracks, and those of disc sub-folders ("CD1", "Disc 2").
        final tracks = objects.map(_trackItem).nonNulls.toList();
        for (final sub in objects.where((o) => o.isContainer).take(20)) {
          tracks.addAll((await _browseAll(control, sub.id, cap: 1000)).map(_trackItem).nonNulls);
        }
        return tracks;
      case BaseItemDtoType.playlist:
        return objects.map(_trackItem).nonNulls.toList();
      case BaseItemDtoType.artist:
      case BaseItemDtoType.genre:
        if (wantsTracks) return _walkTracks(control, objects);
        final containerType = includeItemTypes?.contains("MusicArtist") ?? false ? "MusicArtist" : "MusicAlbum";
        final containers = objects.where((o) => o.isContainer && !_isPlaceholder(o.title)).toList();
        if (containers.isEmpty) return objects.map(_trackItem).nonNulls.toList();
        return containers.map((o) => _containerItem(o, forceType: containerType)).toList();
      default:
        if (wantsTracks) return _walkTracks(control, objects);
        return _mapListing(objects, containerType: "Folder");
    }
  }

  /// Tracks in [objects] and the containers below them, a bounded walk. A
  /// "- All Tracks -"-style container, when present, is read instead of the rest.
  Future<List<BaseItemDto>> _walkTracks(Uri control, List<DidlObject> objects) async {
    final all = objects.where((o) => o.isContainer && _isPlaceholder(o.title)).firstOrNull;
    if (all != null) {
      final inside = await _browseAll(control, all.id, cap: _walkTrackCap);
      if (inside.any((o) => o.isAudioItem)) return inside.map(_trackItem).nonNulls.toList();
    }
    final tracks = <BaseItemDto>[];
    final seen = <String>{};
    final queue = [...objects];
    var opened = 0;
    while (queue.isNotEmpty && tracks.length < _walkTrackCap) {
      final o = queue.removeAt(0);
      if (o.isContainer) {
        if (opened >= _walkContainers || o.isNonMusicContainer || !seen.add(o.refId ?? o.id)) continue;
        opened++;
        queue.addAll(await _browseAll(control, o.id, cap: 2000));
      } else {
        final t = _trackItem(o);
        if (t != null && seen.add(o.refId ?? o.id)) tracks.add(t);
      }
    }
    return tracks;
  }

  Future<List<BaseItemDto>> _search(Uri control, String term, String? includeItemTypes, int? limit) async {
    final types = includeItemTypes ?? "";
    final wantsAll = types.isEmpty;
    final size = limit ?? 50;
    final out = <BaseItemDto>[];

    if (_searchesByClass && _searchesByTitle) {
      Future<List<DidlObject>> find(String cls) async {
        try {
          return (await _client.search(control, dlnaRootId, searchCriteria(cls, term: term), count: size)).objects;
        } on DlnaFault catch (e) {
          _log.info("${config.name}: Search refused: $e");
          return const [];
        }
      }

      if (wantsAll || types.contains("MusicAlbum")) {
        out.addAll(
          _dedupe(
            (await find("object.container.album.musicAlbum")).map((o) => _containerItem(o, forceType: "MusicAlbum")),
          ),
        );
      }
      if (wantsAll || types.contains("MusicArtist")) {
        out.addAll(
          _dedupe((await find("object.container.person")).map((o) => _containerItem(o, forceType: "MusicArtist"))),
        );
      }
      if (wantsAll || types.contains("Audio")) {
        out.addAll((await find("object.item.audioItem")).map(_trackItem).nonNulls);
      }
      return out;
    }

    // No server-side search: match the names of albums and artists.
    final needle = term.toLowerCase();
    for (final (view, type) in [(DlnaView.albums, "MusicAlbum"), (DlnaView.artists, "MusicArtist")]) {
      if (!wantsAll && !types.contains(type)) continue;
      final list = _lists[view] ??= await _listView(control, view);
      out.addAll(list.where((i) => (i.name ?? "").toLowerCase().contains(needle)).take(size));
    }
    return out;
  }

  @override
  Future<BaseItemDto?> getItemById(BaseItemId id) async {
    final control = await _control();
    if (control == null) {
      throw StateError("DLNA server ${config.name} is unreachable.");
    }
    try {
      final result = await _client.browse(control, id.nativeId, metadata: true, count: 1);
      final o = result.objects.firstOrNull;
      if (o == null) return null;
      return o.isContainer ? _containerItem(o) : _trackItem(o);
    } on DlnaFault catch (e) {
      // 701: no such object.
      if (e.code == 701) return null;
      rethrow;
    }
  }

  Future<DidlResource> _resource(BaseItemDto item) async {
    final known = _resources[item.id.nativeId];
    if (known != null) return known;
    final control = await _control();
    if (control == null) throw StateError("DLNA server ${config.name} is unreachable.");
    final result = await _client.browse(control, item.id.nativeId, metadata: true, count: 1);
    final res = result.objects.firstOrNull?.bestAudioResource;
    if (res == null) throw StateError("${item.name} has no playable stream on ${config.name}.");
    _resources[item.id.nativeId] = res;
    return res;
  }

  @override
  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) async {
    final res = await _resource(item);
    return PlayableSource(res.uri, container: res.container ?? item.container);
  }

  @override
  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) =>
      resolveStream(item, transcode: false);

  @override
  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) {
    final tag = item.imageTags?["Primary"];
    if (tag == null || !(tag.startsWith("http://") || tag.startsWith("https://"))) return null;
    return Uri.tryParse(tag);
  }

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
  Future<void> reportPlaybackProgress(
    BaseItemDto item, {
    required Duration position,
    required bool isPaused,
    String? playSessionId,
  }) async {}

  @override
  Future<void> reportPlaybackStopped(BaseItemDto item, {required Duration position, String? playSessionId}) async {}

  @override
  Future<BaseItemDto> createPlaylist(String name, {List<BaseItemId> itemIds = const [], bool isPublic = true}) =>
      throw UnsupportedError("DLNA servers are read-only.");

  @override
  Future<void> addToPlaylist(BaseItemDto playlist, List<BaseItemId> itemIds) =>
      throw UnsupportedError("DLNA servers are read-only.");

  @override
  Future<void> removeFromPlaylist(BaseItemDto playlist, List<String> playlistItemIds) =>
      throw UnsupportedError("DLNA servers are read-only.");

  @override
  Future<void> updatePlaylistMetadata(BaseItemDto playlist, {String? name, bool? isPublic}) =>
      throw UnsupportedError("DLNA servers are read-only.");

  @override
  Future<void> reorderPlaylist(BaseItemDto playlist, List<BaseItemId> orderedItemIds) =>
      throw UnsupportedError("DLNA servers are read-only.");

  @override
  Future<void> deleteItem(BaseItemId id, {required bool isPlaylist}) =>
      throw UnsupportedError("DLNA servers are read-only.");

  @override
  Future<void> logout() async {
    _device = null;
    _client.close();
  }
}
