import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/discovery/discovery_service.dart';
import 'package:diapason/services/discovery/youtube_discover_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

class AutoRadioService {
  AutoRadioService();

  static final _log = Logger("AutoRadioService");

  DiscoveryService get _discovery => GetIt.instance<DiscoveryService>();

  bool get enabled => FinampSettingsHelper.finampSettings.autoRadioEnabled;

  Future<List<BaseItemDto>> extend(BaseItemDto seed, {required Set<String> exclude, int limit = 8}) async {
    if (!enabled) return const [];

    final artist = seed.albumArtist ?? seed.artists?.firstOrNull;
    final title = seed.name;
    if (artist == null || artist.isEmpty || title == null || title.isEmpty) return const [];

    final similar = await _discovery.similarTracks(artist: artist, title: title);
    if (similar.isEmpty) {
      return _fromYouTube(seed, exclude: exclude, limit: limit);
    }

    final resolved = await _discovery.resolve(similar.take(limit * 2).toList());

    final fresh = resolved.where((track) => !exclude.contains(track.id.raw)).take(limit).toList();
    if (fresh.isEmpty) return _fromYouTube(seed, exclude: exclude, limit: limit);

    _log.info("Auto-radio added ${fresh.length} track(s) after '$title'");
    return fresh;
  }

  Future<List<BaseItemDto>> _fromYouTube(BaseItemDto seed, {required Set<String> exclude, required int limit}) async {
    if (!isYouTubeAvailable) return const [];
    try {
      final tracks = await GetIt.instance<YouTubeDiscoverService>().radioFor(
        seed,
        length: limit,
        exclude: exclude.map((id) => BaseItemId(id).nativeId).toSet(),
      );
      _log.info("Auto-radio took ${tracks.length} track(s) from YouTube after '${seed.name}'");
      return tracks.where((t) => !exclude.contains(t.id.raw)).toList();
    } catch (e) {
      _log.fine("YouTube auto-radio failed: $e");
      return const [];
    }
  }
}
