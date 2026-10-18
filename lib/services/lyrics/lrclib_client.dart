import 'dart:convert';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:diapason/services/lyrics/word_sync_parser.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class LrclibClient {
  LrclibClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("LrclibClient");
  static final _base = Uri.parse("https://lrclib.net");

  static const _userAgent = "Diapason (https://github.com/Nytuo/diapason)";

  final http.Client _http;

  Future<LyricDto?> fetch({
    required String title,
    required String artist,
    String? album,
    Duration? duration,
    bool syncedOnly = false,
  }) async {
    if (title.isEmpty || artist.isEmpty) return null;

    final exact = await _get("/api/get", {
      "track_name": title,
      "artist_name": artist,
      if (album != null && album.isNotEmpty) "album_name": album,
      if (duration != null) "duration": "${duration.inSeconds}",
    });
    final fromExact = _toLyrics(exact, syncedOnly: syncedOnly);
    // Several people may have uploaded the same song; only some uploads are word-synced (Lyricsfile). An exact
    // match that is not is still worth checking the other uploads for.
    if (fromExact != null && exact?["hasWordSync"] == true) return fromExact;

    final results = await _getList("/api/search", {"track_name": title, "artist_name": artist});
    final agreeing = results.where((r) => _durationAgrees(r, duration)).toList();
    // Word-synced uploads are rare enough to accept a little more disagreement on the length (uploads round it, and
    // rips differ by a second or two of silence); the closest one wins.
    final wordSynced =
        results
            .where((r) => r["hasWordSync"] == true && _durationAgrees(r, duration, tolerance: _wordSyncTolerance))
            .toList()
          ..sort((a, b) => _durationGap(a, duration).compareTo(_durationGap(b, duration)));
    for (final result in wordSynced) {
      final lyrics = _toLyrics(result, syncedOnly: syncedOnly);
      if (lyrics != null) return lyrics;
    }
    if (fromExact != null) return fromExact;
    for (final result in agreeing) {
      final lyrics = _toLyrics(result, syncedOnly: syncedOnly);
      if (lyrics != null) return lyrics;
    }

    _log.fine("LRCLIB has no ${syncedOnly ? "synced " : ""}lyrics for '$artist - $title'");
    return null;
  }

  static const _tolerance = 2.5;
  static const _wordSyncTolerance = 4.0;

  /// Seconds between the upload's length and the track's (0 when either is unknown).
  static double _durationGap(Map<String, dynamic> result, Duration? duration) {
    final theirs = (result["duration"] as num?)?.toDouble();
    if (duration == null || theirs == null) return 0;
    return (theirs - duration.inMilliseconds / 1000).abs();
  }

  static bool _durationAgrees(Map<String, dynamic> result, Duration? duration, {double tolerance = _tolerance}) =>
      _durationGap(result, duration) <= tolerance;

  LyricDto? _toLyrics(Map<String, dynamic>? body, {required bool syncedOnly}) {
    if (body == null) return null;
    if (body["instrumental"] == true) return null;

    // Lyricsfile (YAML) carries word timings when there are any; it is also synced or plain otherwise.
    final lyricsfile = body["lyricsfile"] as String?;
    if (lyricsfile != null && lyricsfile.trim().isNotEmpty) {
      final parsed = WordSyncParser.parseLyricsfile(lyricsfile);
      if (parsed != null && (!syncedOnly || LrcParser.isSynced(parsed))) {
        if (LrcParser.isSynced(parsed) || body["syncedLyrics"] == null) return parsed;
      }
    }

    final synced = body["syncedLyrics"] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      final parsed = LrcParser.parse(synced);
      if (parsed != null) return parsed;
    }

    if (syncedOnly) return null;

    final plain = body["plainLyrics"] as String?;
    return (plain == null || plain.trim().isEmpty) ? null : LrcParser.plain(plain);
  }

  /// LRCLIB answers 503 now and then under load; one retry after a moment usually gets through.
  Future<http.Response> _request(String path, Map<String, String> query) async {
    final url = _base.replace(path: path, queryParameters: query);
    var response = await _http.get(url, headers: {"User-Agent": _userAgent});
    if (response.statusCode == 503 || response.statusCode == 429) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      response = await _http.get(url, headers: {"User-Agent": _userAgent});
    }
    return response;
  }

  Future<Map<String, dynamic>?> _get(String path, Map<String, String> query) async {
    try {
      final response = await _request(path, query);
      if (response.statusCode != 200) return null;
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      _log.fine("LRCLIB $path failed: $e");
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _getList(String path, Map<String, String> query) async {
    try {
      final response = await _request(path, query);
      if (response.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      return body is List ? body.cast<Map<String, dynamic>>() : const [];
    } catch (e) {
      _log.fine("LRCLIB $path failed: $e");
      return const [];
    }
  }
}
