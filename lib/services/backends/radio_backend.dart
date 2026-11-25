import 'dart:async';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/models/radio_station.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/radio/radio_browser_client.dart';
import 'package:diapason/services/radio/radio_playlist.dart';
import 'package:diapason/services/radio/radio_station_store.dart';
import 'package:logging/logging.dart';

/// Built-in source for internet radio stations (Radio Browser directory and
/// the user's own stations). Station items are live streams: no seeking, no
/// downloads, no scrobbling.
class RadioBackend implements MediaBackend {
  RadioBackend();

  static final _log = Logger("RadioBackend");

  @override
  final MediaSourceConfig config = MediaSourceConfig(
    sourceId: RadioStation.sourceId,
    kind: MediaSourceKind.radio,
    name: "Radio",
  );

  @override
  String get sourceId => config.sourceId;

  @override
  bool get isConnected => true;

  @override
  Future<bool> ping() async => true;

  @override
  BackendCapabilities get capabilities => const BackendCapabilities(favorites: true, search: false);

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
  Future<BaseItemDto?> getItemById(BaseItemId id) async {
    final station = RadioStationStore.find(id.nativeId);
    return station?.toBaseItem(isFavorite: RadioStationStore.isSaved(station.id));
  }

  @override
  Future<List<BaseItemDto>> getInstantMix(BaseItemDto item, {int? limit}) async => const [];

  @override
  Future<List<BaseItemDto>> getRadioStations() async => const [];

  @override
  Future<PlayableSource> resolveStream(BaseItemDto item, {required bool transcode, String? playSessionId}) async {
    final station = RadioStation.fromBaseItem(item) ?? RadioStationStore.find(item.id.nativeId);
    if (station == null) throw StateError("Unknown radio station '${item.name}'.");

    final uuid = RadioStation.directoryUuidOf(item);
    if (uuid != null) {
      // Radio Browser asks clients to report each play; it must not hold up playback.
      unawaited(RadioBrowserClient.instance.countClick(uuid));
    }
    unawaited(RadioStationStore.markPlayed(RadioStationStore.find(station.id) ?? station));

    final resolved = await resolveStationUrl(station);
    return PlayableSource(resolved.uri, container: resolved.isHls ? "hls" : null);
  }

  /// The stream URL to hand to the player. Directory stations come with the
  /// playlist already followed (`url_resolved`), so they are only probed when
  /// they still look like a playlist; custom stations are always checked.
  static Future<({Uri uri, bool isHls})> resolveStationUrl(RadioStation station) async {
    final url = Uri.parse(station.streamUrl);
    if (station.isHls) return (uri: url, isHls: true);
    if (!station.isCustom && !RadioPlaylist.looksLikePlaylistUrl(url)) return (uri: url, isHls: false);
    final resolved = await RadioPlaylist.resolve(url);
    if (resolved.uri != url) _log.info("Resolved '${station.name}' to ${resolved.uri}");
    return resolved;
  }

  @override
  Future<PlayableSource> resolveDownload(BaseItemDto item, {DownloadProfile? transcodingProfile}) {
    throw UnsupportedError("Radio stations are live streams and cannot be downloaded.");
  }

  @override
  Uri? imageUrl(BaseItemDto item, {int? maxWidth, int? maxHeight, int? quality, String? format}) =>
      RadioStation.faviconOf(item);

  @override
  Map<String, String> get imageHeaders => const {};

  @override
  Future<LyricDto?> getLyrics(BaseItemDto item) async => null;

  /// "Favourite" on a station item saves it to (or removes it from) the user's stations.
  @override
  Future<void> setFavorite(BaseItemDto item, {required bool isFavorite}) async {
    if (!isFavorite) return RadioStationStore.remove(item.id.nativeId);
    final station = RadioStationStore.find(item.id.nativeId) ?? RadioStation.fromBaseItem(item);
    if (station != null) await RadioStationStore.save(station);
  }

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
  Future<void> deleteItem(BaseItemId id, {required bool isPlaylist}) {
    throw UnsupportedError("Deleting items is not supported by this source.");
  }

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
