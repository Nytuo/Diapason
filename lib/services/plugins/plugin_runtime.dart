import 'dart:async';
import 'dart:convert';

import 'package:diapason/services/plugins/plugin_host.dart';
import 'package:diapason/services/plugins/plugin_manifest.dart';

/// A call into a plugin failed: it answered with an error, trapped, timed out or is suspended.
class PluginCallException implements Exception {
  PluginCallException(this.message);

  final String message;

  @override
  String toString() => "Plugin call failed: $message";
}

/// Runs a plugin's code. Every call is `method` + JSON params -> JSON result; the methods are listed in
/// docs/PLUGINS.md and map one to one to the extension points.
abstract class PluginRuntime {
  /// [PluginCallException] when the plugin fails; null when it has nothing.
  Future<Object?> call(String method, Map<String, Object?> params);

  Future<void> dispose();
}

/// The methods each extension point is called with.
abstract final class PluginMethods {
  static const lyrics = "lyrics.get";
  static const coverArt = "coverArt.find";
  static const metadata = "metadata.track";
  static const radioSearch = "radio.search";
  static const scrobbleNowPlaying = "scrobbler.nowPlaying";
  static const scrobble = "scrobbler.scrobble";
  static const sourceSearch = "source.search";
  static const sourceBrowse = "source.browse";
  static const sourceStreamUrl = "source.streamUrl";
  static const commandRun = "command.run";
}

/// A plugin without code: each extension point is one HTTP request template and a mapping from the JSON answer, all
/// in `handlers.json`. Its requests go through the same [PluginHostBridge.fetch] as WASM plugins, so the same host
/// checks apply.
class DeclarativeRuntime implements PluginRuntime {
  DeclarativeRuntime._(this._bridge, this._handlers);

  /// The points a declarative plugin may provide; anything else needs code.
  static const supportedPoints = {ExtensionPoint.lyrics, ExtensionPoint.coverArt, ExtensionPoint.radioDirectory};

  static const _methodPoints = {
    PluginMethods.lyrics: ExtensionPoint.lyrics,
    PluginMethods.coverArt: ExtensionPoint.coverArt,
    PluginMethods.radioSearch: ExtensionPoint.radioDirectory,
  };

  static const _responseKeys = {
    ExtensionPoint.lyrics: {"plain", "synced"},
    ExtensionPoint.coverArt: {"urls"},
    ExtensionPoint.radioDirectory: {"items", "name", "streamUrl", "homepage", "imageUrl", "tags", "country"},
  };

  final PluginHostBridge _bridge;
  final Map<ExtensionPoint, _Handler> _handlers;

  /// Checks `handlers.json` against [manifest]; throws [ManifestException] listing what is wrong.
  static DeclarativeRuntime load(PluginManifest manifest, String handlersJson, PluginHostBridge bridge) =>
      DeclarativeRuntime._(bridge, _parse(manifest, handlersJson));

  /// Checks `handlers.json` against [manifest]; throws [ManifestException] listing what is wrong.
  static void validate(PluginManifest manifest, String handlersJson) => _parse(manifest, handlersJson);

  static Map<ExtensionPoint, _Handler> _parse(PluginManifest manifest, String source) {
    final errors = <String>[];
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (e) {
      throw ManifestException(["${manifest.entry} is not valid JSON: ${e.message}"]);
    }
    if (json is! Map) throw ManifestException(["${manifest.entry} is not a JSON object"]);
    final handlers = <ExtensionPoint, _Handler>{};
    for (final extension in manifest.extensions) {
      final point = extension.point;
      if (!supportedPoints.contains(point)) {
        errors.add("a declarative plugin cannot provide '${point.wireName}'");
        continue;
      }
      final raw = json[point.wireName];
      if (raw is! Map || raw["request"] is! Map || raw["response"] is! Map) {
        errors.add("'${point.wireName}' needs a 'request' and a 'response' object");
        continue;
      }
      final request = raw["request"] as Map;
      final url = request["url"];
      if (url is! String || !url.startsWith("https://")) {
        errors.add("'${point.wireName}.request.url' must be an https URL template");
        continue;
      }
      final method = (request["method"] as String?)?.toUpperCase() ?? "GET";
      if (method != "GET" && method != "POST") errors.add("'${point.wireName}.request.method' must be GET or POST");
      final headers = request["headers"];
      if (headers != null && (headers is! Map || headers.values.any((v) => v is! String))) {
        errors.add("'${point.wireName}.request.headers' must map names to strings");
      }
      final response = (raw["response"] as Map).cast<String, Object?>();
      final unknown = response.keys.where((k) => !_responseKeys[point]!.contains(k));
      if (unknown.isNotEmpty) errors.add("'${point.wireName}.response' has unknown keys: ${unknown.join(", ")}");
      for (final entry in response.entries) {
        if (entry.value is! String || !JsonPath.isValid(entry.value as String)) {
          errors.add("'${point.wireName}.response.${entry.key}' must be a JSON path like \$.a.b[0]");
        }
      }
      handlers[point] = _Handler(
        url: url,
        method: method,
        headers: headers is Map ? headers.cast<String, String>() : const {},
        body: request["body"] is String ? request["body"] as String : null,
        response: response.cast<String, String>(),
      );
    }
    if (errors.isNotEmpty) throw ManifestException(errors);
    return handlers;
  }

  @override
  Future<Object?> call(String method, Map<String, Object?> params) async {
    final point = _methodPoints[method];
    final handler = point == null ? null : _handlers[point];
    if (point == null || handler == null) throw PluginCallException("this plugin does not handle $method");

    final url = handler.fill(params, encode: true);
    if (url == null) return null;
    final answer = await _bridge.fetch({
      "url": url,
      "method": handler.method,
      "headers": handler.headers,
      if (handler.body != null) "body": handler.fill(params, template: handler.body!, encode: false) ?? "",
    });
    final status = answer["status"] as int;
    if (status == 404 || status == 204) return null;
    if (status < 200 || status >= 300) throw PluginCallException("HTTP $status");
    final Object? body;
    try {
      body = jsonDecode(answer["body"] as String);
    } on FormatException {
      throw PluginCallException("the answer is not JSON");
    }

    String? first(String key, Object? from) {
      final path = handler.response[key];
      if (path == null) return null;
      final value = JsonPath.evaluate(from, path).firstOrNull;
      return value == null ? null : "$value";
    }

    switch (point) {
      case ExtensionPoint.lyrics:
        return {"plain": first("plain", body), "synced": first("synced", body)};
      case ExtensionPoint.coverArt:
        final path = handler.response["urls"];
        return {"urls": path == null ? const <String>[] : JsonPath.evaluate(body, path).whereType<String>().toList()};
      case ExtensionPoint.radioDirectory:
        final itemsPath = handler.response["items"] ?? r"$[*]";
        return {
          "stations": [
            for (final item in JsonPath.evaluate(body, itemsPath))
              {
                "name": first("name", item),
                "streamUrl": first("streamUrl", item),
                "homepage": first("homepage", item),
                "imageUrl": first("imageUrl", item),
                "tags": first("tags", item)?.split(",").map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
                "country": first("country", item),
              },
          ],
        };
      default:
        throw PluginCallException("this plugin does not handle $method");
    }
  }

  @override
  Future<void> dispose() async {}
}

class _Handler {
  const _Handler({
    required this.url,
    required this.method,
    required this.headers,
    required this.body,
    required this.response,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final Map<String, String> response;

  static final _placeholder = RegExp(r"\{([A-Za-z][A-Za-z0-9_]*)\}");

  /// Replaces `{name}` with the call's parameter. Null when a parameter the template needs is empty: the request
  /// could not mean anything.
  String? fill(Map<String, Object?> params, {String? template, required bool encode}) {
    var missing = false;
    final out = (template ?? url).replaceAllMapped(_placeholder, (m) {
      final value = params[m[1]];
      final text = value == null ? "" : "$value";
      if (text.trim().isEmpty) missing = true;
      return encode ? Uri.encodeComponent(text) : text;
    });
    return missing ? null : out;
  }
}

/// The small JSONPath subset declarative plugins use: `$`, `.key`, `[n]` and `[*]`.
abstract final class JsonPath {
  static final _segment = RegExp(r"\.([A-Za-z_][A-Za-z0-9_-]*)|\[(\d+|\*)\]");

  static bool isValid(String path) {
    if (!path.startsWith(r"$")) return false;
    return path.substring(1).replaceAll(_segment, "").isEmpty;
  }

  static List<Object?> evaluate(Object? json, String path) {
    if (!isValid(path)) return const [];
    var current = <Object?>[json];
    for (final match in _segment.allMatches(path.substring(1))) {
      final next = <Object?>[];
      for (final node in current) {
        final key = match[1];
        final index = match[2];
        if (key != null) {
          if (node is Map && node.containsKey(key)) next.add(node[key]);
        } else if (index == "*") {
          if (node is List) next.addAll(node);
          if (node is Map) next.addAll(node.values);
        } else if (node is List) {
          final i = int.parse(index!);
          if (i < node.length) next.add(node[i]);
        }
      }
      current = next;
    }
    return current.where((v) => v != null).toList();
  }
}
