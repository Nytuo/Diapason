import 'dart:async';
import 'dart:io';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/plugins/extension_points.dart';
import 'package:diapason/services/plugins/plugin_host.dart';
import 'package:diapason/services/plugins/plugin_manager.dart';
import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// The app side of the plugin system: setting it up, and the small helpers the rest of the app calls to consult the
// extension registry. Features read [ExtensionRegistry] directly for anything else.

final _log = Logger("Plugins");

/// Registers [ExtensionRegistry] and [PluginManager], then loads the enabled plugins in the background so a slow or
/// broken plugin never delays startup.
Future<void> setupPlugins() async {
  final registry = ExtensionRegistry()..addListener(PluginCoverArt.clear);
  GetIt.instance.registerSingleton(registry);
  // The browser has no folder to keep plugin packages in: the registry stays empty and Settings → Plugins shows the
  // "not available in the web version" page.
  if (kIsWeb) return;
  final info = await PackageInfo.fromPlatform();
  final root = Directory(p.join((await getApplicationSupportDirectory()).path, "plugins"));
  final manager = PluginManager(
    appVersion: info.version,
    root: root,
    services: appPluginServices(),
    registry: registry,
  );
  GetIt.instance.registerSingleton(manager);
  unawaited(manager.init().catchError((Object e, StackTrace s) => _log.severe("Could not load plugins", e, s)));
}

/// What plugins can reach of the app, each behind its permission in [PluginHostBridge].
PluginHostServices appPluginServices() => PluginHostServices(
  isOffline: () => FinampSettingsHelper.finampSettings.isOffline,
  playerControl: (action) async {
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    switch (action) {
      case "play":
        await player.play();
      case "pause":
        await player.pause();
      case "toggle":
        await player.togglePlayback();
      case "next":
        await player.skipToNext();
      case "previous":
        await player.skipToPrevious();
    }
  },
  nowPlaying: () async {
    final item = GetIt.instance<MusicPlayerBackgroundTask>().mediaItem.valueOrNull;
    if (item == null) return null;
    return {
      "title": item.title,
      "artist": item.artist ?? "",
      "album": item.album ?? "",
      "durationMs": item.duration?.inMilliseconds ?? 0,
    };
  },
  librarySearch: (query, limit) async {
    final items = await GetIt.instance<AggregateBackend>().getItems(
      searchTerm: query,
      includeItemTypes: "Audio,MusicAlbum,MusicArtist",
      limit: limit,
    );
    return [for (final item in items.take(limit)) commandItemFor(item)?.toJson()].nonNulls.toList();
  },
);

ExtensionRegistry? get _registry =>
    GetIt.instance.isRegistered<ExtensionRegistry>() ? GetIt.instance<ExtensionRegistry>() : null;

/// What a command receives for [item], or null for items commands do not apply to.
CommandItem? commandItemFor(BaseItemDto item) {
  final target = switch (BaseItemDtoType.fromItem(item)) {
    BaseItemDtoType.track => CommandTarget.track,
    BaseItemDtoType.album => CommandTarget.album,
    BaseItemDtoType.artist => CommandTarget.artist,
    _ => null,
  };
  if (target == null) return null;
  return CommandItem(
    target: target,
    id: item.id.raw,
    name: item.name ?? "",
    artist: item.albumArtist ?? item.artists?.firstOrNull,
    album: item.album,
  );
}

/// Whether an enabled plugin scrobbles.
bool get hasPluginScrobblers => _registry?.scrobblers.isNotEmpty ?? false;

/// Tells scrobbler plugins about [item]: now playing, or played when [playedAt] is given. Failures stay in the
/// plugins' logs; built-in scrobbling is unaffected.
Future<void> scrobbleToPlugins(BaseItemDto item, {DateTime? playedAt}) async {
  final scrobblers = _registry?.scrobblers ?? const [];
  if (scrobblers.isEmpty) return;
  final track = ScrobbleTrack(
    title: item.name ?? "",
    artist: item.artists?.firstOrNull ?? item.albumArtist ?? "",
    album: item.album,
    duration: item.runTimeTicksDuration(),
  );
  if (track.title.isEmpty || track.artist.isEmpty) return;
  await Future.wait([
    for (final scrobbler in scrobblers)
      playedAt == null ? scrobbler.nowPlaying(track) : scrobbler.scrobble(track, playedAt),
  ]);
}

/// Whether an enabled plugin provides lyrics.
bool get hasLyricsPlugins => _registry?.lyricsProviders.isNotEmpty ?? false;

/// Asks each lyrics plugin in turn; the first answer wins.
Future<(LyricsResult, String)?> lyricsFromPlugins(BaseItemDto item) async {
  final providers = _registry?.lyricsProviders ?? const [];
  if (providers.isEmpty || FinampSettingsHelper.finampSettings.isOffline) return null;
  final artist = item.artists?.firstOrNull ?? item.albumArtist ?? "";
  final title = item.name ?? "";
  if (artist.isEmpty || title.isEmpty) return null;
  final query = LyricsQuery(title: title, artist: artist, album: item.album, duration: item.runTimeTicksDuration());
  for (final provider in providers) {
    final result = await provider.lyrics(query);
    if (result != null) return (result, provider.displayName);
  }
  return null;
}

/// Cover art from plugins for items that have none, remembered for the session (misses included) so lists do not
/// ask again on every rebuild.
abstract final class PluginCoverArt {
  static final _cache = <String, Future<Uri?>>{};
  static const _maxEntries = 2000;

  static CoverArtQuery? _query(BaseItemDto item) {
    final type = BaseItemDtoType.fromItem(item);
    final artist = item.albumArtist ?? item.artists?.firstOrNull;
    return switch (type) {
      BaseItemDtoType.album when item.name != null => CoverArtQuery(artist: artist, album: item.name),
      BaseItemDtoType.track when item.album != null => CoverArtQuery(
        artist: artist,
        album: item.album,
        title: item.name,
      ),
      BaseItemDtoType.artist when item.name != null => CoverArtQuery(artist: item.name, kind: "artist"),
      _ => null,
    };
  }

  /// Whether any plugin could answer; checked synchronously before starting a lookup.
  static bool get available =>
      (_registry?.coverArtProviders.isNotEmpty ?? false) && !FinampSettingsHelper.finampSettings.isOffline;

  static Future<Uri?> lookup(BaseItemDto item) {
    final query = _query(item);
    if (query == null || !available) return Future.value(null);
    if (_cache.length > _maxEntries) _cache.clear();
    return _cache.putIfAbsent(query.cacheKey, () async {
      for (final provider in _registry?.coverArtProviders ?? const <CoverArtProviderExtension>[]) {
        final urls = await provider.coverArt(query);
        if (urls.isNotEmpty) return urls.first;
      }
      return null;
    });
  }

  /// Forget misses and hits, e.g. after a cover plugin was enabled.
  static void clear() => _cache.clear();
}
