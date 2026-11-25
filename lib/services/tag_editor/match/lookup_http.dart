import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Shared HTTP plumbing for the metadata/cover lookups: identifying
/// User-Agent, JSON decoding and a per-host minimum interval between requests
/// (MusicBrainz asks for at most one request per second).
class LookupHttp {
  LookupHttp({http.Client? client, String? version}) : _client = client ?? http.Client(), _version = version;

  static final _log = Logger("TagLookup");

  final http.Client _client;
  String? _version;
  final Map<String, Future<void>> _hostQueues = {};

  /// Wait before retrying a 503.
  Duration retryDelay = const Duration(seconds: 2);

  static const _minIntervals = {"musicbrainz.org": Duration(milliseconds: 1100)};

  Future<String> userAgent() async {
    if (_version == null) {
      try {
        _version = (await PackageInfo.fromPlatform()).version;
      } catch (_) {
        _version = "dev";
      }
    }
    return "Diapason/$_version ( https://github.com/Nytuo/diapason )";
  }

  /// Waits for the host's previous request slot, so calls to a rate-limited
  /// host are serialised and spaced.
  Future<T> _throttled<T>(Uri uri, Future<T> Function() run) {
    final interval = _minIntervals[uri.host];
    if (interval == null) return run();
    final previous = _hostQueues[uri.host] ?? Future<void>.value();
    final result = previous.then((_) => run());
    _hostQueues[uri.host] = result.then((_) {}, onError: (_) {}).then((_) => Future<void>.delayed(interval));
    return result;
  }

  Future<dynamic> getJson(Uri uri) => _throttled(uri, () async {
    Future<http.Response> get() async => _client
        .get(uri, headers: {"User-Agent": await userAgent(), "Accept": "application/json"})
        .timeout(const Duration(seconds: 20));
    var response = await get();
    // MusicBrainz answers 503 when over its global rate limit; one retry.
    if (response.statusCode == 503) {
      await Future<void>.delayed(retryDelay);
      response = await get();
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      _log.warning("GET ${uri.host}${uri.path} failed: HTTP ${response.statusCode}");
      throw LookupException(uri.host, response.statusCode);
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  });

  Future<http.Response> post(Uri uri, {Map<String, String>? body}) => _throttled(uri, () async {
    return _client
        .post(uri, headers: {"User-Agent": await userAgent()}, body: body)
        .timeout(const Duration(seconds: 30));
  });

  Future<List<int>> getBytes(Uri uri) async {
    final response = await _client
        .get(uri, headers: {"User-Agent": await userAgent()})
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) throw LookupException(uri.host, response.statusCode);
    return response.bodyBytes;
  }
}

class LookupException implements Exception {
  const LookupException(this.host, this.statusCode);

  final String host;
  final int statusCode;

  @override
  String toString() => "LookupException: $host answered HTTP $statusCode";
}
