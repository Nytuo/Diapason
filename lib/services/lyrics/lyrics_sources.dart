import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:diapason/services/lyrics/lrclib_client.dart';
import 'package:diapason/services/lyrics/word_sync_parser.dart';
import 'package:diapason/services/lyrics/word_synced_lyrics_client.dart';
import 'package:diapason/services/plugins/plugins.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// How closely lyrics follow the music.
enum LyricsSync {
  plain("Plain"),
  line("Synced"),
  word("Word sync");

  const LyricsSync(this.label);

  final String label;

  static LyricsSync of(LyricDto? lyrics) {
    if (WordSyncParser.hasWordCues(lyrics)) return word;
    if (LrcParser.isSynced(lyrics)) return line;
    return plain;
  }
}

/// Where lyrics came from.
enum LyricsOrigin {
  /// A `.lrc` file next to a local track.
  file,

  /// The music server (Jellyfin, Subsonic, ...): embedded tags or its own lyric files.
  server,

  /// Saved with a downloaded track.
  downloaded,
  lrclib,
  amll,
  netease,

  /// An enabled lyrics plugin; the option's label names it.
  plugin;

  String get databaseName => switch (this) {
    file => "File",
    server => "Server",
    downloaded => "Downloaded",
    lrclib => "LRCLIB",
    amll => "AMLL TTML DB",
    netease => "NetEase",
    plugin => "Plugin",
  };

  bool get isOnlineDatabase => this == lrclib || this == amll || this == netease || this == plugin;
}

class LyricsOption {
  const LyricsOption({required this.origin, required this.lyrics, String? label}) : _label = label;

  final LyricsOrigin origin;
  final LyricDto lyrics;
  final String? _label;

  /// E.g. "My Jellyfin" for the server, "LRCLIB" for a database.
  String get label => _label ?? origin.databaseName;

  LyricsSync get sync => LyricsSync.of(lyrics);

  @override
  String toString() => "LyricsOption($label, ${sync.name})";
}

/// Fetches lyrics from each place they can come from, picks the best automatically, and remembers when the user
/// prefers another source for a track.
class LyricsSources {
  LyricsSources({LyricsChoiceStore? choices}) : choices = choices ?? LyricsChoiceStore();

  static final _log = Logger("LyricsSources");

  final LyricsChoiceStore choices;

  static Set<String> _artists(BaseItemDto item) => {
    ...?item.artists,
    if (item.albumArtist != null) item.albumArtist!,
  }.where((artist) => artist.trim().isNotEmpty).toSet();

  /// The track's own lyrics: a sidecar file for local tracks, the server's otherwise.
  Future<LyricsOption?> fromLibrary(BaseItemDto item) async {
    final backend = GetIt.instance<BackendRegistry>().forItem(item);
    if (backend == null) return null;
    try {
      final lyrics = await backend.getLyrics(item);
      if (lyrics?.lyrics?.isEmpty ?? true) return null;
      final isLocal = backend.config.kind == MediaSourceKind.local;
      return LyricsOption(
        origin: isLocal ? LyricsOrigin.file : LyricsOrigin.server,
        lyrics: lyrics!,
        label: isLocal ? "File (.lrc)" : backend.config.name,
      );
    } catch (e) {
      _log.fine("No library lyrics for '${item.name}': $e");
      return null;
    }
  }

  Future<LyricsOption?> fromLrclib(BaseItemDto item, {bool syncedOnly = false}) async {
    for (final artist in _artists(item)) {
      final lyrics = await GetIt.instance<LrclibClient>().fetch(
        title: item.name ?? "",
        artist: artist,
        album: item.album,
        duration: item.runTimeTicksDuration(),
        syncedOnly: syncedOnly,
      );
      if (lyrics != null) return LyricsOption(origin: LyricsOrigin.lrclib, lyrics: lyrics);
    }
    return null;
  }

  Future<LyricsOption?> fromWordDatabase(BaseItemDto item, LyricsOrigin origin) async {
    assert(origin == LyricsOrigin.amll || origin == LyricsOrigin.netease);
    final lyrics = await GetIt.instance<WordSyncedLyricsClient>().fetch(
      title: item.name ?? "",
      artists: _artists(item),
      duration: item.runTimeTicksDuration(),
      amll: origin == LyricsOrigin.amll,
      netease: origin == LyricsOrigin.netease,
    );
    return lyrics == null ? null : LyricsOption(origin: origin, lyrics: lyrics);
  }

  /// The first lyrics plugin that has lyrics for the track.
  Future<LyricsOption?> fromPlugins(BaseItemDto item) async {
    final found = await lyricsFromPlugins(item);
    if (found == null) return null;
    final (result, name) = found;
    final synced = result.synced == null ? null : LrcParser.parse(result.synced!);
    final lyrics = synced ?? (result.plain == null ? null : LrcParser.plain(result.plain!));
    return lyrics == null ? null : LyricsOption(origin: LyricsOrigin.plugin, lyrics: lyrics, label: name);
  }

  /// The online databases the user allows.
  static List<LyricsOrigin> get enabledDatabases {
    final settings = FinampSettingsHelper.finampSettings;
    return [
      LyricsOrigin.lrclib,
      if (settings.wordSyncedLyricsEnabled) LyricsOrigin.amll,
      if (settings.neteaseLyricsEnabled) LyricsOrigin.netease,
      if (hasLyricsPlugins) LyricsOrigin.plugin,
    ];
  }

  Future<LyricsOption?> fromOrigin(BaseItemDto item, LyricsOrigin origin) => switch (origin) {
    LyricsOrigin.file || LyricsOrigin.server => fromLibrary(item),
    LyricsOrigin.lrclib => fromLrclib(item),
    LyricsOrigin.amll || LyricsOrigin.netease => fromWordDatabase(item, origin),
    LyricsOrigin.plugin => fromPlugins(item),
    LyricsOrigin.downloaded => Future.value(null),
  };

  /// What to show by default: the source the user picked for this track if it still has lyrics, otherwise the
  /// library's lyrics, upgraded from the databases while they are not synced, then not word synced.
  Future<LyricsOption?> automatic(BaseItemDto item) async {
    final preferred = await choices.preferred(item.id);
    if (preferred != null && preferred != LyricsOrigin.downloaded) {
      final chosen = await fromOrigin(item, preferred);
      if (chosen != null) return chosen;
    }

    var best = await fromLibrary(item);
    if (best?.sync != LyricsSync.line && best?.sync != LyricsSync.word) {
      best = await fromLrclib(item, syncedOnly: best != null) ?? best;
    }
    if (best?.sync != LyricsSync.word) {
      for (final origin in enabledDatabases.where((o) => o == LyricsOrigin.amll || o == LyricsOrigin.netease)) {
        final word = await fromWordDatabase(item, origin);
        if (word != null) return word;
      }
    }
    // Plugins come last: built-in sources win, a plugin fills the gaps they leave.
    if (best?.sync != LyricsSync.line && best?.sync != LyricsSync.word && hasLyricsPlugins) {
      final fromPlugin = await fromPlugins(item);
      if (fromPlugin != null && (best == null || fromPlugin.sync != LyricsSync.plain)) return fromPlugin;
    }
    return best;
  }

  /// Everything every source has for the track, for the user to choose from. Sources that have nothing are left out.
  Future<List<LyricsOption>> all(BaseItemDto item, {LyricsOption? known}) async {
    final origins = [LyricsOrigin.server, ...enabledDatabases];
    final found = await Future.wait(
      origins.map((origin) {
        if (known != null &&
            (known.origin == origin || (origin == LyricsOrigin.server && known.origin == LyricsOrigin.file))) {
          return Future.value(known);
        }
        return fromOrigin(item, origin).catchError((Object _) => null);
      }),
    );
    return [if (known?.origin == LyricsOrigin.downloaded) known!, ...found.nonNulls];
  }
}

/// Which lyrics source the user chose for which track, kept across launches.
class LyricsChoiceStore {
  static const _maxEntries = 2000;

  Map<String, String>? _choices;
  File? _file;

  Future<Map<String, String>> _load() async {
    if (_choices != null) return _choices!;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File(p.join(dir.path, "lyrics", "choices.json"));
      if (_file!.existsSync()) {
        return _choices = (jsonDecode(await _file!.readAsString()) as Map).cast<String, String>();
      }
    } catch (_) {}
    return _choices = {};
  }

  Future<LyricsOrigin?> preferred(BaseItemId id) async {
    final name = (await _load())[id.raw];
    return LyricsOrigin.values.where((o) => o.name == name).firstOrNull;
  }

  /// Null forgets the choice (back to automatic).
  Future<void> choose(BaseItemId id, LyricsOrigin? origin) async {
    final choices = await _load();
    choices.remove(id.raw);
    if (origin != null) choices[id.raw] = origin.name;
    while (choices.length > _maxEntries) {
      choices.remove(choices.keys.first);
    }
    try {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(choices));
    } catch (_) {}
  }
}

/// The lyrics the user picked for a track in this session, shown instead of the automatic ones.
final chosenLyricsProvider = StateProvider.family<LyricsOption?, BaseItemId>((ref, id) => null);

/// Every source's lyrics for a track, fetched when the user opens the source picker.
final lyricsOptionsProvider = FutureProvider.autoDispose.family<List<LyricsOption>, (BaseItemDto, LyricsOption?)>(
  (ref, args) => GetIt.instance<LyricsSources>().all(args.$1, known: args.$2),
);
