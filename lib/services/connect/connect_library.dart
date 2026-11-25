import 'dart:io';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_slices.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/item_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// The library side of Diapason Connect protocol 2: what `GET browse`, `GET art` and the `playItem` command do on the
/// device that answers them. The watch also uses the listing and track resolution on its own sources.
final _log = Logger("ConnectLibrary");

AggregateBackend get _library => GetIt.instance<AggregateBackend>();

/// How many results of each kind a search returns.
const _searchPerKind = 15;

/// The items a browse request names, from this device's enabled sources.
Future<List<BaseItemDto>> browseLibraryItems(ConnectBrowseRequest request) async {
  final start = request.start;
  final limit = request.limit;
  switch (request.view) {
    case ConnectBrowseView.albums:
      return _library.getItems(includeItemTypes: "MusicAlbum", sortBy: "SortName", startIndex: start, limit: limit);
    case ConnectBrowseView.artists:
      return _library.getItems(
        includeItemTypes: "MusicArtist",
        sortBy: "SortName",
        artistType: ArtistType.albumArtist,
        startIndex: start,
        limit: limit,
      );
    case ConnectBrowseView.playlists:
      return _library.getItems(includeItemTypes: "Playlist", sortBy: "SortName", startIndex: start, limit: limit);
    case ConnectBrowseView.recent:
      final tracks = await _library.getItems(
        includeItemTypes: "Audio",
        sortBy: "DatePlayed",
        sortOrder: "Descending",
        startIndex: start,
        limit: limit,
      );
      return tracks.where((t) => t.userData?.lastPlayedDate != null).toList();
    case ConnectBrowseView.favorites:
      return _library.getItems(
        includeItemTypes: "Audio",
        isFavorite: true,
        sortBy: "SortName",
        startIndex: start,
        limit: limit,
      );
    case ConnectBrowseView.search:
      if (start > 0) return const [];
      final query = request.query ?? "";
      final results = await Future.wait([
        for (final type in const ["MusicArtist", "MusicAlbum", "Audio"])
          _library
              .getItems(includeItemTypes: type, searchTerm: query, limit: _searchPerKind)
              .catchError((Object e) => <BaseItemDto>[]),
      ]);
      return results.expand((r) => r).toList();
    case ConnectBrowseView.children:
      final parent = await _library.getItemById(BaseItemId(request.parentId!));
      if (parent == null) return const [];
      final children = await childrenOf(parent);
      if (start >= children.length) return const [];
      return children.sublist(start, (start + limit).clamp(0, children.length));
  }
}

/// What a container shows when opened: an artist's albums, the tracks of anything else (in play order).
Future<List<BaseItemDto>> childrenOf(BaseItemDto parent) async {
  if (BaseItemDtoType.fromItem(parent) == BaseItemDtoType.artist) {
    return _library.getItems(
      parentItem: parent,
      includeItemTypes: "MusicAlbum",
      sortBy: "PremiereDate,ProductionYear,SortName",
      sortOrder: "Ascending",
      artistType: ArtistType.albumArtist,
    );
  }
  return tracksToPlay(parent);
}

/// The tracks playing [item] plays, in order.
Future<List<BaseItemDto>> tracksToPlay(BaseItemDto item) =>
    loadChildTracksFromBaseItem(item: item, sortConfig: SortAndFilterConfiguration.defaultForItem(item));

/// [item] as a row of a browse listing.
ConnectBrowseItem toBrowseItem(BaseItemDto item) {
  final type = switch (BaseItemDtoType.fromItem(item)) {
    BaseItemDtoType.track => ConnectBrowseItem.track,
    BaseItemDtoType.album => ConnectBrowseItem.album,
    BaseItemDtoType.artist => ConnectBrowseItem.artist,
    BaseItemDtoType.playlist => ConnectBrowseItem.playlist,
    _ => ConnectBrowseItem.other,
  };
  final subtitle = switch (type) {
    ConnectBrowseItem.track || ConnectBrowseItem.album => item.albumArtist ?? item.artists?.firstOrNull ?? "",
    ConnectBrowseItem.playlist => item.childCount == null ? "" : "${item.childCount}",
    _ => "",
  };
  return ConnectBrowseItem(
    id: item.id.raw,
    type: type,
    title: item.name ?? "",
    subtitle: subtitle,
    duration: type == ConnectBrowseItem.track ? (item.runTimeTicksDuration()?.inMilliseconds ?? 0) / 1000 : 0,
    hasArt: _imageUrl(item) != null,
  );
}

Uri? _imageUrl(BaseItemDto item, {int size = 200}) {
  if (!GetIt.instance.isRegistered<BackendRegistry>()) return null;
  try {
    return GetIt.instance<BackendRegistry>().forItem(item)?.imageUrl(item, maxWidth: size, maxHeight: size);
  } catch (_) {
    return null;
  }
}

/// [item]'s artwork as a URL and the headers fetching it needs, for this device to load itself.
({Uri url, Map<String, String> headers})? artworkOf(BaseItemDto item, {int size = 200}) {
  final url = _imageUrl(item, size: size);
  if (url == null) return null;
  final backend = GetIt.instance<BackendRegistry>().forItem(item);
  return (url: url, headers: backend?.imageHeaders ?? const {});
}

/// The bytes of [id]'s artwork, for a controller that cannot reach the server (or a local file) itself.
Future<({List<int> bytes, String contentType})?> artworkBytes(String id, {int size = 200, http.Client? client}) async {
  final item = await _library.getItemById(BaseItemId(id));
  if (item == null) return null;
  final art = artworkOf(item, size: size.clamp(32, 600));
  if (art == null) return null;
  try {
    if (art.url.scheme == "file") {
      final file = File.fromUri(art.url);
      if (!await file.exists()) return null;
      final lower = file.path.toLowerCase();
      return (bytes: await file.readAsBytes(), contentType: lower.endsWith(".png") ? "image/png" : "image/jpeg");
    }
    if (art.url.scheme != "http" && art.url.scheme != "https") return null;
    final c = client ?? http.Client();
    try {
      final response = await c.get(art.url, headers: art.headers).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return (bytes: response.bodyBytes, contentType: response.headers["content-type"] ?? "image/jpeg");
    } finally {
      if (client == null) c.close();
    }
  } catch (e) {
    _log.fine("No artwork for $id: $e");
    return null;
  }
}

/// The items [ids] stand for, in order; unknown ids are dropped.
Future<List<BaseItemDto>> resolveLibraryIds(List<String> ids) async {
  final items = await Future.wait(ids.map((id) => _library.getItemById(BaseItemId(id)).catchError((Object _) => null)));
  return items.nonNulls.toList();
}

/// The tracks a `playItem` request means: everything one container plays, or the tracks listed.
Future<List<BaseItemDto>> tracksForRequest(List<BaseItemDto> items) async {
  if (items.length == 1) return tracksToPlay(items.single);
  return items.where((i) => BaseItemDtoType.fromItem(i) == BaseItemDtoType.track).toList();
}

/// Ids named by a `playItem` command: `id` (one item, played whole) or `ids` (a list of tracks).
List<String> playItemIds(Map<String, dynamic> args) {
  final ids = args["ids"];
  if (ids is List) return ids.whereType<String>().where((id) => id.isNotEmpty).take(500).toList();
  final id = args["id"];
  return id is String && id.isNotEmpty ? [id] : const [];
}

/// Does what a `playItem` command asks, on this device's player. False when nothing playable was found.
Future<bool> playLibraryItems(Map<String, dynamic> args, {required QueueItemSource fallbackSource}) async {
  final items = await resolveLibraryIds(playItemIds(args));
  if (items.isEmpty) return false;
  final tracks = await tracksForRequest(items);
  if (tracks.isEmpty) return false;

  final mode = ConnectPlayMode.parse(args["mode"]);
  final source = items.length == 1 ? QueueItemSource.fromBaseItem(items.single) : fallbackSource;
  final queue = GetIt.instance<QueueService>();
  final start = ((args["startIndex"] as num?)?.toInt() ?? 0).clamp(0, tracks.length - 1);
  switch (mode) {
    case ConnectPlayMode.play || ConnectPlayMode.shuffle:
      await queue.startPlayback(
        items: tracks,
        source: source,
        order: mode == ConnectPlayMode.shuffle ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear,
        startingIndex: mode == ConnectPlayMode.shuffle ? null : start,
      );
    case ConnectPlayMode.next:
      await queue.addNext(PlayableSlice.simple(tracks, source));
    case ConnectPlayMode.queue:
      await queue.addToQueue(PlayableSlice.simple(tracks, source));
  }
  _log.info("Connect playItem (${mode.name}): ${tracks.length} track(s)");
  return true;
}
