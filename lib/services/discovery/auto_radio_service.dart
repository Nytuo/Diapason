import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/discovery/discovery_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
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
      _log.fine("No similar tracks for '$artist - $title'; auto-radio has nothing to add");
      return const [];
    }

    final resolved = await _discovery.resolve(similar.take(limit * 2).toList());

    final fresh = resolved.where((track) => !exclude.contains(track.id.raw)).take(limit).toList();

    _log.info("Auto-radio added ${fresh.length} track(s) after '$title'");
    return fresh;
  }
}
