import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Raised by the host when a plugin asks for something it was not granted. Plugins see it as an error response.
class PluginPermissionDenied implements Exception {
  PluginPermissionDenied(this.message);

  final String message;

  @override
  String toString() => "Permission denied: $message";
}

enum PluginLogLevel { debug, info, warning, error }

class PluginLogEntry {
  PluginLogEntry(this.level, this.message) : time = DateTime.now();

  final DateTime time;
  final PluginLogLevel level;
  final String message;
}

/// The last few hundred lines a plugin (or the host about that plugin) logged. Also forwarded to the app log under
/// `Plugin:<id>`.
class PluginLog {
  PluginLog(this.pluginId) : _logger = Logger("Plugin:$pluginId");

  static const capacity = 500;

  final String pluginId;
  final Logger _logger;
  final _entries = ListQueue<PluginLogEntry>();
  final _changes = StreamController<void>.broadcast();

  List<PluginLogEntry> get entries => List.unmodifiable(_entries);

  Stream<void> get changes => _changes.stream;

  void add(PluginLogLevel level, String message) {
    final trimmed = message.length > 2000 ? "${message.substring(0, 2000)}…" : message;
    _entries.addLast(PluginLogEntry(level, trimmed));
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    switch (level) {
      case PluginLogLevel.debug:
        _logger.fine(trimmed);
      case PluginLogLevel.info:
        _logger.info(trimmed);
      case PluginLogLevel.warning:
        _logger.warning(trimmed);
      case PluginLogLevel.error:
        _logger.severe(trimmed);
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  void clear() {
    _entries.clear();
    if (!_changes.isClosed) _changes.add(null);
  }
}

/// A plugin's own key-value store. Nothing else of the file system is reachable.
abstract class PluginStorage {
  static const maxBytes = 1024 * 1024;
  static const maxKeyLength = 200;

  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> delete(String key);
  Future<List<String>> keys();
  Future<void> clear();
}

class MemoryPluginStorage implements PluginStorage {
  final values = <String, String>{};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async {
    _checkSize(values, key, value);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<List<String>> keys() async => values.keys.toList();

  @override
  Future<void> clear() async => values.clear();
}

void _checkSize(Map<String, String> current, String key, String value) {
  if (key.isEmpty || key.length > PluginStorage.maxKeyLength) {
    throw ArgumentError("storage keys are 1 to ${PluginStorage.maxKeyLength} characters");
  }
  var total = key.length + value.length;
  current.forEach((k, v) {
    if (k != key) total += k.length + v.length;
  });
  if (total > PluginStorage.maxBytes) throw StateError("plugin storage is full (1 MiB)");
}

/// One JSON file in the plugin's data folder.
class FilePluginStorage implements PluginStorage {
  FilePluginStorage(this.file);

  final File file;
  Map<String, String>? _cache;

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    try {
      if (await file.exists()) {
        return _cache = (jsonDecode(await file.readAsString()) as Map).cast<String, String>();
      }
    } catch (_) {}
    return _cache = {};
  }

  Future<void> _save() async {
    await file.parent.create(recursive: true);
    final tmp = File("${file.path}.tmp");
    await tmp.writeAsString(jsonEncode(_cache));
    await tmp.rename(file.path);
  }

  @override
  Future<String?> get(String key) async => (await _load())[key];

  @override
  Future<void> set(String key, String value) async {
    final values = await _load();
    _checkSize(values, key, value);
    values[key] = value;
    await _save();
  }

  @override
  Future<void> delete(String key) async {
    final values = await _load();
    if (values.remove(key) != null) await _save();
  }

  @override
  Future<List<String>> keys() async => (await _load()).keys.toList();

  @override
  Future<void> clear() async {
    _cache = {};
    if (await file.exists()) await file.delete();
  }
}

/// App features the host bridge can reach on a plugin's behalf, each behind its permission. Injected so the bridge
/// can be tested without the player or the backends.
class PluginHostServices {
  const PluginHostServices({required this.isOffline, this.playerControl, this.nowPlaying, this.librarySearch});

  final bool Function() isOffline;

  /// `play`, `pause`, `toggle`, `next`, `previous`.
  final Future<void> Function(String action)? playerControl;
  final Future<Map<String, Object?>?> Function()? nowPlaying;
  final Future<List<Map<String, Object?>>> Function(String query, int limit)? librarySearch;
}

/// Everything a plugin can ask the app for. Every request goes through [handle], which checks the plugin's granted
/// permissions first; a plugin runtime has no other way out.
class PluginHostBridge {
  PluginHostBridge({
    required this.pluginId,
    required this.granted,
    required this.log,
    required this.storage,
    required this.services,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const maxResponseBytes = 2 * 1024 * 1024;
  static const maxRequestBodyBytes = 256 * 1024;
  static const maxRedirects = 5;
  static const fetchTimeout = Duration(seconds: 10);
  static const userAgent = "Diapason-Plugin (https://github.com/Nytuo/Diapason)";

  static const _forbiddenHeaders = {"host", "cookie", "content-length", "connection", "transfer-encoding"};

  final String pluginId;

  /// Approved permissions; only these are honoured even if the manifest declares more.
  final List<PluginPermission> granted;
  final PluginLog log;
  final PluginStorage storage;
  final PluginHostServices services;
  final http.Client _http;

  NetworkPermission? get _network => granted.whereType<NetworkPermission>().firstOrNull;

  bool _has<T extends PluginPermission>() => granted.whereType<T>().isNotEmpty;

  /// Whether the plugin may reach [url]: https, a granted host, and the app is online.
  bool mayReach(Uri url) => url.isScheme("https") && (_network?.allows(url.host) ?? false);

  void checkUrl(Uri url) {
    if (!url.isScheme("https")) throw PluginPermissionDenied("only https URLs are allowed (${url.scheme})");
    if (!(_network?.allows(url.host) ?? false)) {
      throw PluginPermissionDenied("host '${url.host}' is not among the plugin's approved hosts");
    }
  }

  /// Answers one JSON request from a plugin: `{"op": "...", ...}`. Never throws; errors come back as
  /// `{"error": "...", "denied": true|false}`.
  Future<Map<String, Object?>> handle(Map<String, Object?> request) async {
    final op = request["op"];
    try {
      final result = switch (op) {
        "log" => _log(request),
        "http.fetch" => fetch(request),
        "storage.get" => _storage(request, (key) async => {"value": await storage.get(key)}),
        "storage.set" => _storage(request, (key) async {
          final value = request["value"];
          if (value is! String) throw ArgumentError("'value' must be a string");
          await storage.set(key, value);
          return const {};
        }),
        "storage.delete" => _storage(request, (key) async {
          await storage.delete(key);
          return const {};
        }),
        "storage.keys" => _requireStorage().then((_) async => {"keys": await storage.keys()}),
        "player.control" => _playerControl(request),
        "player.nowPlaying" => _nowPlaying(),
        "library.search" => _librarySearch(request),
        _ => throw ArgumentError("unknown host operation '$op'"),
      };
      return await result;
    } on PluginPermissionDenied catch (e) {
      log.add(PluginLogLevel.warning, "Blocked $op: ${e.message}");
      return {"error": e.message, "denied": true};
    } catch (e) {
      log.add(PluginLogLevel.debug, "$op failed: $e");
      return {"error": e.toString(), "denied": false};
    }
  }

  Future<Map<String, Object?>> _log(Map<String, Object?> request) async {
    final level = PluginLogLevel.values.where((l) => l.name == request["level"]).firstOrNull ?? PluginLogLevel.info;
    log.add(level, "${request["message"]}");
    return const {};
  }

  Future<void> _requireStorage() async {
    if (!_has<StoragePermission>()) throw PluginPermissionDenied("storage was not granted");
  }

  Future<Map<String, Object?>> _storage(
    Map<String, Object?> request,
    Future<Map<String, Object?>> Function(String key) action,
  ) async {
    await _requireStorage();
    final key = request["key"];
    if (key is! String) throw ArgumentError("'key' must be a string");
    return action(key);
  }

  Future<Map<String, Object?>> _playerControl(Map<String, Object?> request) async {
    if (!_has<PlaybackControlPermission>()) throw PluginPermissionDenied("playback control was not granted");
    final action = request["action"];
    const actions = {"play", "pause", "toggle", "next", "previous"};
    if (action is! String || !actions.contains(action)) throw ArgumentError("unknown player action '$action'");
    final control = services.playerControl;
    if (control == null) throw StateError("playback control is not available here");
    await control(action);
    return const {};
  }

  Future<Map<String, Object?>> _nowPlaying() async {
    if (!_has<NowPlayingPermission>()) throw PluginPermissionDenied("now playing was not granted");
    return {"track": await services.nowPlaying?.call()};
  }

  Future<Map<String, Object?>> _librarySearch(Map<String, Object?> request) async {
    if (!_has<LibraryReadPermission>()) throw PluginPermissionDenied("library read was not granted");
    final query = request["query"];
    if (query is! String || query.trim().isEmpty) throw ArgumentError("'query' must be a non-empty string");
    final limit = (request["limit"] as num?)?.toInt().clamp(1, 100) ?? 20;
    final search = services.librarySearch;
    if (search == null) throw StateError("library search is not available here");
    return {"items": await search(query, limit)};
  }

  /// `{"url", "method"?, "headers"?, "body"?}` -> `{"status", "headers", "body"}`. Redirects are followed by hand so
  /// every hop is checked against the approved hosts.
  Future<Map<String, Object?>> fetch(Map<String, Object?> request) async {
    final rawUrl = request["url"];
    if (rawUrl is! String) throw ArgumentError("'url' must be a string");
    var url = Uri.tryParse(rawUrl);
    if (url == null) throw ArgumentError("invalid URL '$rawUrl'");
    checkUrl(url);
    if (services.isOffline()) throw PluginPermissionDenied("Diapason is in offline mode");

    var method = (request["method"] as String?)?.toUpperCase() ?? "GET";
    if (!const {"GET", "POST", "PUT", "DELETE", "HEAD", "PATCH"}.contains(method)) {
      throw ArgumentError("unsupported method '$method'");
    }
    final headers = <String, String>{"User-Agent": userAgent};
    final rawHeaders = request["headers"];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        final name = "$key";
        if (!_forbiddenHeaders.contains(name.toLowerCase())) headers[name] = "$value";
      });
    }
    String? body = request["body"] as String?;
    if (body != null && utf8.encode(body).length > maxRequestBodyBytes) throw ArgumentError("request body too large");

    final started = DateTime.now();
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final outgoing = http.Request(method, url!)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body != null) outgoing.body = body;
      final response = await _http.send(outgoing).timeout(fetchTimeout);
      if (response.isRedirect || (response.statusCode >= 300 && response.statusCode < 400)) {
        final location = response.headers["location"];
        unawaited(response.stream.drain<void>().catchError((_) {}));
        if (location == null) throw StateError("redirect without location");
        final next = url.resolve(location);
        checkUrl(next);
        url = next;
        if (response.statusCode == 303 ||
            ((response.statusCode == 301 || response.statusCode == 302) && method == "POST")) {
          method = "GET";
          body = null;
        }
        continue;
      }
      final bytes = await _readCapped(response.stream).timeout(fetchTimeout);
      log.add(
        PluginLogLevel.debug,
        "$method ${url.host}${url.path} -> ${response.statusCode} (${bytes.length} B, "
        "${DateTime.now().difference(started).inMilliseconds} ms)",
      );
      return {
        "status": response.statusCode,
        "url": url.toString(),
        "headers": {
          for (final entry in response.headers.entries)
            if (entry.key.toLowerCase() != "set-cookie") entry.key.toLowerCase(): entry.value,
        },
        "body": utf8.decode(bytes, allowMalformed: true),
      };
    }
    throw StateError("too many redirects");
  }

  static Future<List<int>> _readCapped(Stream<List<int>> stream) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      out.add(chunk);
      if (out.length > maxResponseBytes) throw StateError("response larger than 2 MiB");
    }
    return out.takeBytes();
  }
}
