import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class LastFmClient {
  LastFmClient({required this.apiKey, required this.apiSecret, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  static final _log = Logger("LastFmClient");
  static final _base = Uri.parse("https://ws.audioscrobbler.com/2.0/");

  final String apiKey;
  final String apiSecret;

  final http.Client _http;

  bool get isConfigured => apiKey.isNotEmpty && apiSecret.isNotEmpty;

  String _sign(Map<String, String> params) {
    final sorted = params.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final key in sorted) {
      buffer.write(key);
      buffer.write(params[key]);
    }
    buffer.write(apiSecret);
    return md5.convert(utf8.encode(buffer.toString())).toString();
  }

  Future<String?> requestToken() async {
    final body = await _call({"method": "auth.getToken"}, signed: true, post: false);
    return body?["token"] as String?;
  }

  Uri authorizationUrl(String token) =>
      Uri.parse("https://www.last.fm/api/auth/?api_key=$apiKey&token=$token");

  Future<({String sessionKey, String username})?> session(String token) async {
    final body = await _call({"method": "auth.getSession", "token": token}, signed: true, post: false);
    final session = body?["session"] as Map<String, dynamic>?;
    if (session == null) return null;
    return (sessionKey: session["key"] as String, username: session["name"] as String);
  }

  Future<bool> updateNowPlaying(BaseItemDto item, String sessionKey) async {
    final params = _trackParams(item);
    if (params == null) return false;
    return await _call({...params, "method": "track.updateNowPlaying", "sk": sessionKey}, signed: true) != null;
  }

  Future<bool> scrobble(BaseItemDto item, String sessionKey, {DateTime? startedAt}) async {
    final params = _trackParams(item);
    if (params == null) return false;
    final started = startedAt ?? DateTime.now();
    return await _call({
          ...params,
          "method": "track.scrobble",
          "sk": sessionKey,
          "timestamp": "${started.millisecondsSinceEpoch ~/ 1000}",
        }, signed: true) !=
        null;
  }

  Map<String, String>? _trackParams(BaseItemDto item) {
    final artist = item.albumArtist ?? item.artists?.firstOrNull;
    final title = item.name;
    if (artist == null || artist.isEmpty || title == null || title.isEmpty) return null;
    return {
      "artist": artist,
      "track": title,
      if (item.album != null) "album": item.album!,
      if (item.runTimeTicksDuration() case final duration?) "duration": "${duration.inSeconds}",
    };
  }

  Future<Map<String, dynamic>?> _call(Map<String, String> params, {bool signed = false, bool post = true}) async {
    if (!isConfigured) return null;

    final all = {...params, "api_key": apiKey};
    if (signed) all["api_sig"] = _sign(all);
    all["format"] = "json";

    try {
      final response = post
          ? await _http.post(_base, body: all)
          : await _http.get(_base.replace(queryParameters: all));

      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (body["error"] != null) {
        _log.warning("Last.fm ${params["method"]} failed: ${body["message"]}");
        return null;
      }
      return body;
    } catch (e) {
      _log.fine("Last.fm ${params["method"]} failed: $e");
      return null;
    }
  }
}
