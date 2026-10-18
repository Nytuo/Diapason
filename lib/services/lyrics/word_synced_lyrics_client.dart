import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/word_sync_parser.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Finds word-by-word ("karaoke") lyrics for a track.
///
/// Sources, in order:
/// * the AMLL TTML database (https://github.com/amll-dev/amll-ttml-db), a community-made, CC0 set of Apple Music
///   style word-timed lyrics. Its index is downloaded and kept for a few days; lookups are by title and artist.
/// * NetEase Cloud Music's word-timed "YRC" lyrics, which cover far more (Western) music. Unofficial, and it sends
///   the title and artist to NetEase, so only used when the user turns it on.
class WordSyncedLyricsClient {
  WordSyncedLyricsClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("WordSyncedLyrics");

  static const _amllBase = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main";
  static const _indexMaxAge = Duration(days: 3);
  static const _userAgent = "Diapason (https://github.com/Nytuo/diapason)";
  static const _durationTolerance = Duration(seconds: 3);

  final http.Client _http;

  /// Normalised "title|artist" → raw TTML file, latest submission wins.
  Map<String, String>? _amllIndex;
  Future<Map<String, String>?>? _amllIndexLoading;

  Future<LyricDto?> fetch({
    required String title,
    required Iterable<String> artists,
    Duration? duration,
    bool amll = true,
    bool netease = false,
  }) async {
    if (title.trim().isEmpty) return null;
    final artistList = artists.where((a) => a.trim().isNotEmpty).toList();
    if (artistList.isEmpty) return null;

    if (amll) {
      final fromAmll = await _fromAmll(title, artistList, duration);
      if (fromAmll != null) return fromAmll;
    }
    if (netease) {
      final fromNetease = await _fromNetease(title, artistList, duration);
      if (fromNetease != null) return fromNetease;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Matching helpers
  // ---------------------------------------------------------------------------

  static final _bracketed = RegExp(r"[\(\[（【][^\)\]）】]*[\)\]）】]");
  static final _featuring = RegExp(r"\s+(feat\.?|ft\.?|featuring|with)\s+.*$", caseSensitive: false);
  static final _nonWord = RegExp(r"[^\p{L}\p{N}]+", unicode: true);

  /// "Song (Remastered 2011) - feat. X" and "song" compare equal.
  static String normalise(String value) {
    var v = value.toLowerCase();
    v = v.replaceAll(_bracketed, " ");
    v = v.split(" - ").first;
    v = v.replaceAll(_featuring, "");
    return v.replaceAll(_nonWord, "");
  }

  static String _key(String title, String artist) => "${normalise(title)}|${normalise(artist)}";

  // ---------------------------------------------------------------------------
  // AMLL TTML DB
  // ---------------------------------------------------------------------------

  Future<LyricDto?> _fromAmll(String title, List<String> artists, Duration? duration) async {
    final index = await _loadAmllIndex();
    if (index == null) return null;

    String? file;
    for (final artist in artists) {
      file = index[_key(title, artist)];
      if (file != null) break;
    }
    if (file == null) return null;

    try {
      final response = await _http
          .get(Uri.parse("$_amllBase/raw-lyrics/$file"), headers: {"User-Agent": _userAgent})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final body = utf8.decode(response.bodyBytes);
      if (!_ttmlDurationAgrees(body, duration)) {
        _log.fine("AMLL lyrics for '$title' are for a different length of track; skipping");
        return null;
      }
      final lyrics = WordSyncParser.parseTtml(body);
      if (lyrics != null) _log.fine("Got word-synced lyrics for '$title' from the AMLL database");
      return lyrics;
    } catch (e) {
      _log.fine("AMLL lyrics fetch failed: $e");
      return null;
    }
  }

  static final _bodyDur = RegExp(r'<body[^>]*\sdur="([^"]+)"');

  static bool _ttmlDurationAgrees(String ttml, Duration? duration) {
    if (duration == null) return true;
    final match = _bodyDur.firstMatch(ttml);
    final theirs = WordSyncParser.parseTtmlTime(match?.group(1));
    if (theirs == null) return true;
    return (theirs - duration).abs() <= _durationTolerance * 2;
  }

  Future<Map<String, String>?> _loadAmllIndex() {
    final cached = _amllIndex;
    if (cached != null) return Future.value(cached);
    return _amllIndexLoading ??= _readAmllIndex().whenComplete(() => _amllIndexLoading = null);
  }

  Future<Map<String, String>?> _readAmllIndex() async {
    File? file;
    try {
      final support = await getApplicationSupportDirectory();
      file = File(p.join(support.path, "lyrics", "amll-index.jsonl"));
    } catch (_) {}

    String? content;
    final fresh =
        file != null && file.existsSync() && DateTime.now().difference(file.lastModifiedSync()) < _indexMaxAge;
    if (fresh) {
      content = await file.readAsString();
    } else {
      try {
        final response = await _http
            .get(Uri.parse("$_amllBase/metadata/raw-lyrics-index.jsonl"), headers: {"User-Agent": _userAgent})
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) {
          content = utf8.decode(response.bodyBytes);
          if (file != null) {
            await file.parent.create(recursive: true);
            await file.writeAsString(content);
          }
        }
      } catch (e) {
        _log.fine("Could not download the AMLL lyrics index: $e");
      }
      // Offline or GitHub unreachable: a stale index still beats none.
      if (content == null && file != null && file.existsSync()) content = await file.readAsString();
    }
    if (content == null) return null;

    final index = <String, String>{};
    for (final line in const LineSplitter().convert(content)) {
      if (line.isEmpty) continue;
      try {
        final entry = jsonDecode(line) as Map<String, dynamic>;
        final rawFile = entry["rawLyricFile"] as String?;
        if (rawFile == null) continue;
        final meta = <String, List<String>>{
          for (final pair in (entry["metadata"] as List).cast<List<dynamic>>())
            pair[0] as String: (pair[1] as List).cast<String>(),
        };
        for (final name in meta["musicName"] ?? const <String>[]) {
          for (final artist in meta["artists"] ?? const <String>[]) {
            index[_key(name, artist)] = rawFile; // later lines are newer submissions
          }
        }
      } catch (_) {}
    }
    _log.info("Loaded the AMLL lyrics index (${index.length} title/artist keys)");
    return _amllIndex = index;
  }

  // ---------------------------------------------------------------------------
  // NetEase Cloud Music
  // ---------------------------------------------------------------------------

  static const _neteaseHeaders = {"User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com/"};

  Future<LyricDto?> _fromNetease(String title, List<String> artists, Duration? duration) async {
    try {
      final search = await _http
          .post(
            Uri.https("music.163.com", "/api/cloudsearch/pc", {
              "s": "$title ${artists.first}",
              "type": "1",
              "limit": "8",
            }),
            headers: _neteaseHeaders,
          )
          .timeout(const Duration(seconds: 8));
      if (search.statusCode != 200) return null;
      final songs = ((jsonDecode(utf8.decode(search.bodyBytes)) as Map)["result"] as Map?)?["songs"] as List?;
      if (songs == null) return null;

      final wantedTitle = normalise(title);
      final wantedArtists = artists.map(normalise).toSet();
      for (final song in songs.cast<Map<String, dynamic>>()) {
        if (normalise(song["name"] as String? ?? "") != wantedTitle) continue;
        final theirArtists = ((song["ar"] as List?) ?? const [])
            .map((a) => normalise((a as Map)["name"] as String? ?? ""))
            .toSet();
        if (theirArtists.intersection(wantedArtists).isEmpty) continue;
        final dt = (song["dt"] as num?)?.toInt();
        if (duration != null && dt != null && (Duration(milliseconds: dt) - duration).abs() > _durationTolerance) {
          continue;
        }

        final lyrics = await _neteaseLyrics((song["id"] as num).toInt());
        if (lyrics != null) {
          _log.fine("Got word-synced lyrics for '$title' from NetEase");
          return lyrics;
        }
      }
    } catch (e) {
      _log.fine("NetEase lyrics lookup failed: $e");
    }
    return null;
  }

  Future<LyricDto?> _neteaseLyrics(int id) async {
    final response = await _http
        .get(
          Uri.https("music.163.com", "/api/song/lyric/v1", {"id": "$id", "lv": "0", "yv": "1", "tv": "0", "rv": "0"}),
          headers: _neteaseHeaders,
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final yrc = (body["yrc"] as Map?)?["lyric"] as String?;
    if (yrc == null || yrc.trim().isEmpty) return null;
    return WordSyncParser.parseYrc(yrc);
  }
}
