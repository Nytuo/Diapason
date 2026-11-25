import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:flutter/foundation.dart';

// The typed contracts the app calls into. Plugins implement them through their runtime (see plugin_extensions.dart),
// but nothing here is plugin specific: built-in Dart code can register an implementation the same way, so features
// such as a radio directory can consume `ExtensionRegistry.radioDirectories` without caring where entries come from.

/// What every contributed extension says about itself.
abstract interface class Extension {
  /// Unique within the registry, e.g. `org.example.lyrics/lyrics`.
  String get extensionId;

  /// Shown to the user, e.g. as the lyrics source label.
  String get displayName;

  /// The plugin (or built-in module) that contributed it; used to remove everything it registered at once.
  String get ownerId;
}

// ---- Lyrics ---------------------------------------------------------------------------------------------------------

class LyricsQuery {
  const LyricsQuery({required this.title, required this.artist, this.album, this.duration});

  final String title;
  final String artist;
  final String? album;
  final Duration? duration;

  Map<String, Object?> toJson() => {
    "title": title,
    "artist": artist,
    "album": album ?? "",
    "durationMs": duration?.inMilliseconds ?? 0,
    "durationSeconds": duration?.inSeconds ?? 0,
  };
}

/// Either LRC text (`[mm:ss.xx] line`) or plain text; the app parses it.
class LyricsResult {
  const LyricsResult({this.synced, this.plain});

  final String? synced;
  final String? plain;

  bool get isEmpty => (synced?.trim().isEmpty ?? true) && (plain?.trim().isEmpty ?? true);
}

abstract interface class LyricsProviderExtension implements Extension {
  Future<LyricsResult?> lyrics(LyricsQuery query);
}

// ---- Cover art / metadata -------------------------------------------------------------------------------------------

class CoverArtQuery {
  const CoverArtQuery({this.artist, this.album, this.title, this.kind = "album"});

  final String? artist;
  final String? album;
  final String? title;

  /// `album`, `track` or `artist`.
  final String kind;

  Map<String, Object?> toJson() => {"artist": artist ?? "", "album": album ?? "", "title": title ?? "", "kind": kind};

  String get cacheKey => "$kind|${artist ?? ""}|${album ?? ""}|${title ?? ""}".toLowerCase();
}

abstract interface class CoverArtProviderExtension implements Extension {
  /// Image URLs, best first. Plugin-backed providers only return URLs on hosts the plugin was granted.
  Future<List<Uri>> coverArt(CoverArtQuery query);
}

class TrackMetadataResult {
  const TrackMetadataResult({this.genres = const [], this.year, this.bio, this.extra = const {}});

  final List<String> genres;
  final int? year;
  final String? bio;
  final Map<String, String> extra;
}

abstract interface class MetadataProviderExtension implements Extension {
  Future<TrackMetadataResult?> trackMetadata(LyricsQuery query);
}

// ---- Radio directory ------------------------------------------------------------------------------------------------

class RadioStationResult {
  const RadioStationResult({
    required this.name,
    required this.streamUrl,
    this.homepage,
    this.imageUrl,
    this.tags = const [],
    this.country,
  });

  final String name;
  final Uri streamUrl;
  final Uri? homepage;
  final Uri? imageUrl;
  final List<String> tags;
  final String? country;
}

abstract interface class RadioDirectoryExtension implements Extension {
  Future<List<RadioStationResult>> searchStations(String query, {int limit = 50});
}

// ---- Scrobbler ------------------------------------------------------------------------------------------------------

class ScrobbleTrack {
  const ScrobbleTrack({required this.title, required this.artist, this.album, this.duration});

  final String title;
  final String artist;
  final String? album;
  final Duration? duration;

  Map<String, Object?> toJson() => {
    "title": title,
    "artist": artist,
    "album": album ?? "",
    "durationMs": duration?.inMilliseconds ?? 0,
  };
}

abstract interface class ScrobblerExtension implements Extension {
  Future<void> nowPlaying(ScrobbleTrack track);
  Future<void> scrobble(ScrobbleTrack track, DateTime playedAt);
}

// ---- Source (read-only) ---------------------------------------------------------------------------------------------

class SourceItem {
  const SourceItem({
    required this.id,
    required this.type,
    required this.title,
    this.artist,
    this.album,
    this.duration,
    this.imageUrl,
  });

  final String id;

  /// `track`, `album`, `artist`, `playlist` or `folder`.
  final String type;
  final String title;
  final String? artist;
  final String? album;
  final Duration? duration;
  final Uri? imageUrl;
}

abstract interface class SourceProviderExtension implements Extension {
  Future<List<SourceItem>> search(String query);

  /// Children of [parentId], or the root when null.
  Future<List<SourceItem>> browse(String? parentId);

  /// A playable URL for a track.
  Future<Uri?> streamUrl(String trackId);
}

// ---- Commands -------------------------------------------------------------------------------------------------------

class CommandItem {
  const CommandItem({required this.target, required this.id, required this.name, this.artist, this.album});

  final CommandTarget target;
  final String id;
  final String name;
  final String? artist;
  final String? album;

  Map<String, Object?> toJson() => {
    "type": target.name,
    "id": id,
    "name": name,
    "title": name,
    "artist": artist ?? "",
    "album": album ?? "",
  };
}

/// What running a command asks the app to do afterwards.
class CommandResult {
  const CommandResult({this.message, this.openUrl});

  final String? message;
  final Uri? openUrl;
}

abstract interface class ItemCommandExtension implements Extension {
  String get title;
  bool appliesTo(CommandTarget target);
  Future<CommandResult> run(CommandItem item);
}

/// Every extension currently contributed, by type. Listen to it to rebuild when plugins are enabled or disabled.
class ExtensionRegistry extends ChangeNotifier {
  final _extensions = <String, Extension>{};

  void register(Extension extension) {
    _extensions[extension.extensionId] = extension;
    notifyListeners();
  }

  /// Removes everything [ownerId] registered.
  void unregisterOwner(String ownerId) {
    final before = _extensions.length;
    _extensions.removeWhere((_, e) => e.ownerId == ownerId);
    if (_extensions.length != before) notifyListeners();
  }

  Iterable<T> _of<T extends Extension>() => _extensions.values.whereType<T>();

  List<LyricsProviderExtension> get lyricsProviders => _of<LyricsProviderExtension>().toList();
  List<CoverArtProviderExtension> get coverArtProviders => _of<CoverArtProviderExtension>().toList();
  List<MetadataProviderExtension> get metadataProviders => _of<MetadataProviderExtension>().toList();
  List<RadioDirectoryExtension> get radioDirectories => _of<RadioDirectoryExtension>().toList();
  List<ScrobblerExtension> get scrobblers => _of<ScrobblerExtension>().toList();
  List<SourceProviderExtension> get sources => _of<SourceProviderExtension>().toList();

  List<ItemCommandExtension> commandsFor(CommandTarget target) =>
      _of<ItemCommandExtension>().where((c) => c.appliesTo(target)).toList();

  List<Extension> ownedBy(String ownerId) => _extensions.values.where((e) => e.ownerId == ownerId).toList();
}
