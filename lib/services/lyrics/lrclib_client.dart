import 'dart:convert';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
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
    if (fromExact != null) return fromExact;

    final results = await _getList("/api/search", {"track_name": title, "artist_name": artist});
    for (final result in results) {
      if (!_durationAgrees(result, duration)) continue;

      final lyrics = _toLyrics(result, syncedOnly: syncedOnly);
      if (lyrics != null) return lyrics;
    }

    _log.fine("LRCLIB has no ${syncedOnly ? "synced " : ""}lyrics for '$artist - $title'");
    return null;
  }

  static bool _durationAgrees(Map<String, dynamic> result, Duration? duration) {
    if (duration == null) return true;

    final theirs = (result["duration"] as num?)?.toDouble();
    if (theirs == null) return true;

    return (theirs - duration.inSeconds).abs() <= 2;
  }

  LyricDto? _toLyrics(Map<String, dynamic>? body, {required bool syncedOnly}) {
    if (body == null) return null;
    if (body["instrumental"] == true) return null;

    final synced = body["syncedLyrics"] as String?;
    if (synced != null && synced.trim().isNotEmpty) {
      final parsed = LrcParser.parse(synced);
      if (parsed != null) return parsed;
    }

    if (syncedOnly) return null;

    final plain = body["plainLyrics"] as String?;
    return (plain == null || plain.trim().isEmpty) ? null : LrcParser.plain(plain);
  }

  Future<Map<String, dynamic>?> _get(String path, Map<String, String> query) async {
    try {
      final response = await _http.get(
        _base.replace(path: path, queryParameters: query),
        headers: {"User-Agent": _userAgent},
      );
      if (response.statusCode != 200) return null;
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      _log.fine("LRCLIB $path failed: $e");
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _getList(String path, Map<String, String> query) async {
    try {
      final response = await _http.get(
        _base.replace(path: path, queryParameters: query),
        headers: {"User-Agent": _userAgent},
      );
      if (response.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      return body is List ? body.cast<Map<String, dynamic>>() : const [];
    } catch (e) {
      _log.fine("LRCLIB $path failed: $e");
      return const [];
    }
  }
}
