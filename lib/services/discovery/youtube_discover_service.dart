import 'package:collection/collection.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

class YouTubeDiscoverService {
  static final _log = Logger("YouTubeDiscoverService");

  YouTubeService get _youtube => GetIt.instance<YouTubeService>();

  static const _defaultLength = 40;

  Future<List<BaseItemDto>> radioFromSeed(BaseItemDto seed, {int length = _defaultLength}) async {
    final chain = <BaseItemDto>[seed];
    final seen = <String>{seed.id.nativeId};

    var current = seed;
    while (chain.length < length) {
      final related = await _youtube.relatedTracks(current);
      final next = related.firstWhereOrNull((track) => seen.add(track.id.nativeId));
      if (next == null) {
        _log.fine("Discover chain dried up after ${chain.length} tracks.");
        break;
      }
      chain.add(next);
      current = next;
    }
    return chain;
  }

  Future<List<BaseItemDto>> radioFromQuery(String query, {int length = _defaultLength}) async {
    final matches = await _youtube.search(query);
    if (matches.isEmpty) return const [];
    return radioFromSeed(matches.first, length: length);
  }

  Future<List<BaseItemDto>> radioFromPlaylistTail(List<BaseItemDto> playlist, {int length = _defaultLength}) async {
    for (final track in playlist.reversed) {
      final seed = await _seedForTrack(track);
      if (seed != null) return radioFromSeed(seed, length: length);
    }
    _log.warning("Couldn't seed a YouTube discover from any of the ${playlist.length} playlist tracks.");
    return const [];
  }

  Future<BaseItemDto?> _seedForTrack(BaseItemDto track) async {
    if (track.id.sourceId == YouTubeService.sourceId) return track;

    final artist = track.albumArtist ?? track.artists?.firstOrNull ?? "";
    final query = "$artist ${track.name ?? ""}".trim();
    if (query.isEmpty) return null;

    final matches = await _youtube.search(query);
    return matches.firstOrNull;
  }
}
