import 'package:diapason/services/plugins/extension_points.dart';
import 'package:diapason/services/plugins/plugin_host.dart';
import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:diapason/services/plugins/plugin_runtime.dart';

/// Turns a loaded plugin into typed extensions. Each adapter validates what the plugin answers, so the app never
/// sees malformed data, and logs failures to the plugin's log instead of throwing into the caller: a broken plugin
/// makes a lookup come back empty, nothing else.
List<Extension> extensionsFor(PluginManifest manifest, PluginRuntime runtime, PluginHostBridge bridge) {
  final base = _PluginCaller(manifest, runtime, bridge);
  return [
    for (final extension in manifest.extensions)
      switch (extension.point) {
        ExtensionPoint.lyrics => _Lyrics(base, extension),
        ExtensionPoint.coverArt => _CoverArt(base, extension),
        ExtensionPoint.metadata => _Metadata(base, extension),
        ExtensionPoint.radioDirectory => _RadioDirectory(base, extension),
        ExtensionPoint.scrobbler => _Scrobbler(base, extension),
        ExtensionPoint.source => _Source(base, extension),
        ExtensionPoint.command => _Command(base, extension),
      },
  ];
}

class _PluginCaller {
  _PluginCaller(this.manifest, this.runtime, this.bridge);

  final PluginManifest manifest;
  final PluginRuntime runtime;
  final PluginHostBridge bridge;

  /// The result as a map, or null when the plugin has nothing or failed (logged).
  Future<Map<String, Object?>?> call(String method, Map<String, Object?> params) async {
    try {
      final result = await runtime.call(method, params);
      if (result == null) return null;
      if (result is! Map) {
        bridge.log.add(PluginLogLevel.warning, "$method returned ${result.runtimeType}, expected an object");
        return null;
      }
      return result.cast<String, Object?>();
    } on PluginPermissionDenied catch (e) {
      bridge.log.add(PluginLogLevel.warning, "$method blocked: ${e.message}");
    } on PluginCallException catch (e) {
      bridge.log.add(PluginLogLevel.warning, "$method failed: ${e.message}");
    } catch (e) {
      bridge.log.add(PluginLogLevel.warning, "$method failed: $e");
    }
    return null;
  }

  /// Same as [call], but failures reach the caller (for commands, whose user is waiting for an answer).
  Future<Map<String, Object?>?> callOrThrow(String method, Map<String, Object?> params) async {
    final result = await runtime.call(method, params);
    if (result == null) return null;
    if (result is! Map) throw PluginCallException("$method returned ${result.runtimeType}, expected an object");
    return result.cast<String, Object?>();
  }

  /// An http(s) URL the plugin may hand to the app. Images and streams are loaded by the app, not by the plugin, so
  /// they too must be on a host the plugin was granted.
  Uri? grantedUrl(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.isScheme("https") || uri.host.isEmpty) return null;
    if (!bridge.mayReach(uri)) {
      bridge.log.add(PluginLogLevel.warning, "Dropped ${uri.host} URL: not among the approved hosts");
      return null;
    }
    return uri;
  }
}

abstract class _Base implements Extension {
  _Base(this.caller, this.declaration);

  final _PluginCaller caller;
  final PluginExtension declaration;

  @override
  String get extensionId =>
      "${caller.manifest.id}/${declaration.point.wireName}${declaration.id == null ? "" : "/${declaration.id}"}";

  @override
  String get displayName => declaration.title ?? caller.manifest.name;

  @override
  String get ownerId => caller.manifest.id;
}

String? _string(Object? value, {int max = 10000}) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > max ? trimmed.substring(0, max) : trimmed;
}

class _Lyrics extends _Base implements LyricsProviderExtension {
  _Lyrics(super.caller, super.declaration);

  static const _maxLength = 200000;

  @override
  Future<LyricsResult?> lyrics(LyricsQuery query) async {
    final result = await caller.call(PluginMethods.lyrics, query.toJson());
    if (result == null) return null;
    final lyrics = LyricsResult(
      synced: _string(result["synced"], max: _maxLength),
      plain: _string(result["plain"], max: _maxLength),
    );
    return lyrics.isEmpty ? null : lyrics;
  }
}

class _CoverArt extends _Base implements CoverArtProviderExtension {
  _CoverArt(super.caller, super.declaration);

  @override
  Future<List<Uri>> coverArt(CoverArtQuery query) async {
    final result = await caller.call(PluginMethods.coverArt, query.toJson());
    final urls = result?["urls"];
    if (urls is! List) return const [];
    return urls.take(20).map(caller.grantedUrl).nonNulls.toList();
  }
}

class _Metadata extends _Base implements MetadataProviderExtension {
  _Metadata(super.caller, super.declaration);

  @override
  Future<TrackMetadataResult?> trackMetadata(LyricsQuery query) async {
    final result = await caller.call(PluginMethods.metadata, query.toJson());
    if (result == null) return null;
    final genres = result["genres"];
    final extra = result["extra"];
    return TrackMetadataResult(
      genres: genres is List ? genres.map((g) => _string(g, max: 100)).nonNulls.take(50).toList() : const [],
      year: result["year"] is num ? (result["year"] as num).toInt() : null,
      bio: _string(result["bio"], max: 20000),
      extra: extra is Map
          ? {
              for (final entry in extra.entries.take(50))
                if (_string(entry.value, max: 1000) case final value?) "${entry.key}": value,
            }
          : const {},
    );
  }
}

class _RadioDirectory extends _Base implements RadioDirectoryExtension {
  _RadioDirectory(super.caller, super.declaration);

  @override
  Future<List<RadioStationResult>> searchStations(String query, {int limit = 50}) async {
    final result = await caller.call(PluginMethods.radioSearch, {"query": query, "limit": limit});
    final stations = result?["stations"];
    if (stations is! List) return const [];
    return [
      for (final raw in stations.take(limit))
        if (raw is Map)
          if ((_string(raw["name"], max: 200), _streamUrl(raw["streamUrl"])) case (final name?, final stream?))
            RadioStationResult(
              name: name,
              streamUrl: stream,
              homepage: Uri.tryParse(_string(raw["homepage"]) ?? ""),
              imageUrl: caller.grantedUrl(raw["imageUrl"]),
              tags: raw["tags"] is List
                  ? (raw["tags"] as List).map((t) => _string(t, max: 50)).nonNulls.toList()
                  : const [],
              country: _string(raw["country"], max: 100),
            ),
    ];
  }

  /// Station streams live on many hosts a directory cannot list in advance; they are played, never fetched by the
  /// plugin, so any http(s) URL is accepted.
  static Uri? _streamUrl(Object? value) {
    final uri = Uri.tryParse(_string(value) ?? "");
    return uri != null && (uri.isScheme("https") || uri.isScheme("http")) && uri.host.isNotEmpty ? uri : null;
  }
}

class _Scrobbler extends _Base implements ScrobblerExtension {
  _Scrobbler(super.caller, super.declaration);

  @override
  Future<void> nowPlaying(ScrobbleTrack track) => caller.call(PluginMethods.scrobbleNowPlaying, track.toJson());

  @override
  Future<void> scrobble(ScrobbleTrack track, DateTime playedAt) => caller.call(PluginMethods.scrobble, {
    ...track.toJson(),
    "playedAt": playedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
  });
}

class _Source extends _Base implements SourceProviderExtension {
  _Source(super.caller, super.declaration);

  List<SourceItem> _items(Map<String, Object?>? result) {
    final items = result?["items"];
    if (items is! List) return const [];
    return [
      for (final raw in items.take(500))
        if (raw is Map)
          if ((_string(raw["id"], max: 500), _string(raw["type"], max: 20), _string(raw["title"], max: 500)) case (
            final id?,
            final type?,
            final title?,
          ))
            if (const {"track", "album", "artist", "playlist", "folder"}.contains(type))
              SourceItem(
                id: id,
                type: type,
                title: title,
                artist: _string(raw["artist"], max: 500),
                album: _string(raw["album"], max: 500),
                duration: raw["durationMs"] is num ? Duration(milliseconds: (raw["durationMs"] as num).toInt()) : null,
                imageUrl: caller.grantedUrl(raw["imageUrl"]),
              ),
    ];
  }

  @override
  Future<List<SourceItem>> search(String query) async =>
      _items(await caller.call(PluginMethods.sourceSearch, {"query": query}));

  @override
  Future<List<SourceItem>> browse(String? parentId) async =>
      _items(await caller.call(PluginMethods.sourceBrowse, {"parentId": parentId}));

  @override
  Future<Uri?> streamUrl(String trackId) async =>
      caller.grantedUrl((await caller.call(PluginMethods.sourceStreamUrl, {"id": trackId}))?["url"]);
}

class _Command extends _Base implements ItemCommandExtension {
  _Command(super.caller, super.declaration);

  @override
  String get title => declaration.title ?? caller.manifest.name;

  @override
  bool appliesTo(CommandTarget target) => declaration.targets.contains(target);

  @override
  Future<CommandResult> run(CommandItem item) async {
    final result = await caller.callOrThrow(PluginMethods.commandRun, {
      "command": declaration.id,
      "item": item.toJson(),
    });
    final openUrl = Uri.tryParse(_string(result?["openUrl"]) ?? "");
    return CommandResult(
      message: _string(result?["message"], max: 300),
      // Opening a page is the user's browser's business, but only web pages: no custom schemes or files.
      openUrl: openUrl != null && (openUrl.isScheme("https") || openUrl.isScheme("http")) ? openUrl : null,
    );
  }
}
