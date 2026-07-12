import 'dart:convert';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class ListenBrainzClient {
  ListenBrainzClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("ListenBrainzClient");
  static final _base = Uri.parse("https://api.listenbrainz.org");

  final http.Client _http;

  Future<bool> validateToken(String token) async {
    try {
      final response = await _http.get(
        _base.replace(path: "/1/validate-token"),
        headers: {"Authorization": "Token $token"},
      );
      if (response.statusCode != 200) return false;
      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return body["valid"] == true;
    } catch (e) {
      _log.fine("Token validation failed: $e");
      return false;
    }
  }

  Future<bool> submitPlayingNow(BaseItemDto item, String token) =>
      _submit(item, token, listenType: "playing_now", startedAt: null);

  Future<bool> submitListen(BaseItemDto item, String token, {DateTime? startedAt}) =>
      _submit(item, token, listenType: "single", startedAt: startedAt ?? DateTime.now());

  Future<bool> _submit(
    BaseItemDto item,
    String token, {
    required String listenType,
    required DateTime? startedAt,
  }) async {
    final artist = item.albumArtist ?? item.artists?.firstOrNull;
    final title = item.name;
    if (artist == null || artist.isEmpty || title == null || title.isEmpty) return false;

    final payload = <String, dynamic>{
      "track_metadata": {
        "artist_name": artist,
        "track_name": title,
        if (item.album != null) "release_name": item.album,
        "additional_info": {
          "media_player": "Diapason",
          "submission_client": "Diapason",
          if (item.runTimeTicksDuration() case final duration?) "duration_ms": duration.inMilliseconds,
          if (item.indexNumber != null) "tracknumber": item.indexNumber,
        },
      },
      if (startedAt != null) "listened_at": startedAt.millisecondsSinceEpoch ~/ 1000,
    };

    try {
      final response = await _http.post(
        _base.replace(path: "/1/submit-listens"),
        headers: {"Authorization": "Token $token", "Content-Type": "application/json"},
        body: jsonEncode({
          "listen_type": listenType,
          "payload": [payload],
        }),
      );
      if (response.statusCode != 200) {
        _log.warning("ListenBrainz rejected a $listenType: HTTP ${response.statusCode} ${response.body}");
        return false;
      }
      return true;
    } catch (e) {
      _log.fine("ListenBrainz $listenType failed: $e");
      return false;
    }
  }
}
