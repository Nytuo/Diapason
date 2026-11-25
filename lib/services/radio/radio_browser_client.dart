import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:diapason/models/radio_station.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// How a directory listing is ordered.
enum RadioBrowserOrder {
  /// Most clicked overall ("Top").
  clickCount("clickcount"),

  /// Most gaining clicks lately ("Trending").
  clickTrend("clicktrend"),

  /// Most voted.
  votes("votes"),
  name("name");

  const RadioBrowserOrder(this.apiName);

  final String apiName;
}

/// Client for the community Radio Browser directory (https://www.radio-browser.info).
///
/// Follows the API's usage notes: the server is picked at random from the list
/// `all.api.radio-browser.info` advertises (falling back to its DNS records),
/// every request carries a descriptive `Diapason/<version>` User-Agent, and
/// playing a station goes through [countClick].
class RadioBrowserClient {
  RadioBrowserClient({http.Client? client, String? userAgent, List<String>? servers})
    : _client = client ?? http.Client(),
      _userAgent = userAgent,
      _servers = servers;

  static final _log = Logger("RadioBrowserClient");

  static RadioBrowserClient? _instance;

  static RadioBrowserClient get instance => _instance ??= RadioBrowserClient();

  static const _discoveryHost = "all.api.radio-browser.info";
  static const _fallbackServers = [
    "de1.api.radio-browser.info",
    "de2.api.radio-browser.info",
    "fi1.api.radio-browser.info",
  ];

  final http.Client _client;
  String? _userAgent;
  List<String>? _servers;
  String? _server;
  final _random = Random();

  Future<String> get userAgent async {
    if (_userAgent != null) return _userAgent!;
    try {
      final info = await PackageInfo.fromPlatform();
      _userAgent = "Diapason/${info.version}";
    } catch (_) {
      _userAgent = "Diapason";
    }
    return _userAgent!;
  }

  /// Picks the API servers: `/json/servers` on the round-robin host, then its
  /// DNS records reverse-resolved, then a short built-in list.
  Future<List<String>> _discoverServers() async {
    if (_servers != null && _servers!.isNotEmpty) return _servers!;
    try {
      final response = await _client
          .get(Uri.https(_discoveryHost, "/json/servers"), headers: {"User-Agent": await userAgent})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final names = parseServers(jsonDecode(response.body));
        if (names.isNotEmpty) return _servers = names;
      }
    } catch (e) {
      _log.fine("Server list from $_discoveryHost unavailable: $e");
    }
    try {
      final addresses = await InternetAddress.lookup(_discoveryHost).timeout(const Duration(seconds: 5));
      final names = <String>{};
      for (final address in addresses) {
        try {
          final host = (await address.reverse().timeout(const Duration(seconds: 3))).host;
          if (host.endsWith(".api.radio-browser.info")) names.add(host);
        } catch (_) {}
      }
      if (names.isNotEmpty) return _servers = names.toList();
    } catch (e) {
      _log.fine("DNS lookup of $_discoveryHost failed: $e");
    }
    return _servers = List.of(_fallbackServers);
  }

  /// Host names from a `/json/servers` response, deduplicated.
  static List<String> parseServers(Object? json) {
    if (json is! List) return const [];
    return json
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => e["name"]?.toString().trim() ?? "")
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
  }

  Future<Object?> _get(String path, [Map<String, String>? query]) async {
    final servers = await _discoverServers();
    _server ??= servers[_random.nextInt(servers.length)];
    Object? lastError;
    // Try the chosen server, then the others, so one server being down does
    // not break the directory.
    final order = [_server!, ...servers.where((s) => s != _server)];
    for (final server in order.take(3)) {
      try {
        final response = await _client
            .get(Uri.https(server, path, query), headers: {"User-Agent": await userAgent, "Accept": "application/json"})
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw HttpException("Radio Browser answered ${response.statusCode}", uri: Uri.https(server, path));
        }
        _server = server;
        return jsonDecode(utf8.decode(response.bodyBytes));
      } catch (e) {
        lastError = e;
        _log.warning("Radio Browser request $path on $server failed: $e");
      }
    }
    throw lastError ?? StateError("No Radio Browser server reachable");
  }

  /// Searches stations. Empty filters are ignored; broken stations are hidden.
  Future<List<RadioStation>> search({
    String? name,
    String? countryCode,
    String? language,
    String? tag,
    RadioBrowserOrder order = RadioBrowserOrder.clickCount,
    int limit = 50,
    int offset = 0,
  }) async {
    final query = <String, String>{
      if ((name ?? "").trim().isNotEmpty) "name": name!.trim(),
      if ((countryCode ?? "").isNotEmpty) "countrycode": countryCode!,
      if ((language ?? "").isNotEmpty) "language": language!,
      if ((tag ?? "").isNotEmpty) ...{"tag": tag!, "tagExact": "true"},
      "order": order.apiName,
      "reverse": order == RadioBrowserOrder.name ? "false" : "true",
      "hidebroken": "true",
      "limit": "$limit",
      "offset": "$offset",
    };
    return RadioStation.listFromRadioBrowserJson(await _get("/json/stations/search", query));
  }

  Future<List<RadioStation>> top({int limit = 50, int offset = 0}) =>
      search(order: RadioBrowserOrder.clickCount, limit: limit, offset: offset);

  Future<List<RadioStation>> trending({int limit = 50, int offset = 0}) =>
      search(order: RadioBrowserOrder.clickTrend, limit: limit, offset: offset);

  Future<List<RadioStation>> byUuids(List<String> uuids) async {
    if (uuids.isEmpty) return const [];
    return RadioStation.listFromRadioBrowserJson(await _get("/json/stations/byuuid", {"uuids": uuids.join(",")}));
  }

  Future<List<RadioBrowserCategory>> countries() async => RadioBrowserCategory.listFromJson(
    await _get("/json/countries", {"order": "stationcount", "reverse": "true", "hidebroken": "true"}),
    codeKey: "iso_3166_1",
  );

  Future<List<RadioBrowserCategory>> languages() async => RadioBrowserCategory.listFromJson(
    await _get("/json/languages", {"order": "stationcount", "reverse": "true", "hidebroken": "true", "limit": "150"}),
    codeKey: "iso_639",
  );

  Future<List<RadioBrowserCategory>> tags() async => RadioBrowserCategory.listFromJson(
    await _get("/json/tags", {"order": "stationcount", "reverse": "true", "hidebroken": "true", "limit": "200"}),
  );

  /// Counts a play of [uuid], as the API asks clients to do whenever a user
  /// starts a station, and returns the stream URL it gives back, if any.
  Future<Uri?> countClick(String uuid) async {
    try {
      final json = await _get("/json/url/${Uri.encodeComponent(uuid)}");
      return parseClickUrl(json);
    } catch (e) {
      _log.fine("Click count for $uuid failed: $e");
      return null;
    }
  }

  static Uri? parseClickUrl(Object? json) {
    if (json is! Map) return null;
    if (json["ok"] == false || json["ok"] == "false") return null;
    final url = json["url"]?.toString() ?? "";
    final uri = Uri.tryParse(url);
    return uri == null || uri.host.isEmpty ? null : uri;
  }
}
