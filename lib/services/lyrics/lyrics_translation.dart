import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Services that can translate lyrics. Both need the user's own server or key: there is no keyless one, because the
/// free endpoints that exist are either unofficial (scraped) or too limited to translate a song.
enum LyricsTranslationProvider {
  libreTranslate("libretranslate", "LibreTranslate"),
  deepl("deepl", "DeepL");

  const LyricsTranslationProvider(this.id, this.label);

  final String id;
  final String label;

  static LyricsTranslationProvider fromId(String? id) =>
      values.firstWhere((p) => p.id == id, orElse: () => LyricsTranslationProvider.libreTranslate);
}

/// Where translations come from, set in the lyrics settings. Kept in its own box rather than in the settings so the API
/// key isn't part of settings exports or logs.
@immutable
class LyricsTranslationConfig {
  const LyricsTranslationConfig({
    this.provider = LyricsTranslationProvider.libreTranslate,
    this.url = "",
    this.apiKey = "",
    this.targetLanguage = "",
  });

  final LyricsTranslationProvider provider;

  /// LibreTranslate server, e.g. `https://libretranslate.example.org`.
  final String url;

  /// LibreTranslate key (optional) or DeepL key (required).
  final String apiKey;

  /// ISO 639-1 code; empty means the app's language.
  final String targetLanguage;

  bool get isUsable => switch (provider) {
    LyricsTranslationProvider.libreTranslate => Uri.tryParse(url.trim())?.hasScheme ?? false,
    LyricsTranslationProvider.deepl => apiKey.trim().isNotEmpty,
  };

  LyricsTranslationConfig copyWith({
    LyricsTranslationProvider? provider,
    String? url,
    String? apiKey,
    String? targetLanguage,
  }) => LyricsTranslationConfig(
    provider: provider ?? this.provider,
    url: url ?? this.url,
    apiKey: apiKey ?? this.apiKey,
    targetLanguage: targetLanguage ?? this.targetLanguage,
  );

  Map<String, String> toJson() => {
    "provider": provider.id,
    "url": url,
    "apiKey": apiKey,
    "targetLanguage": targetLanguage,
  };

  factory LyricsTranslationConfig.fromJson(Map<String, dynamic> json) => LyricsTranslationConfig(
    provider: LyricsTranslationProvider.fromId(json["provider"] as String?),
    url: json["url"] as String? ?? "",
    apiKey: json["apiKey"] as String? ?? "",
    targetLanguage: json["targetLanguage"] as String? ?? "",
  );

  @override
  bool operator ==(Object other) =>
      other is LyricsTranslationConfig &&
      other.provider == provider &&
      other.url == url &&
      other.apiKey == apiKey &&
      other.targetLanguage == targetLanguage;

  @override
  int get hashCode => Object.hash(provider, url, apiKey, targetLanguage);
}

/// A track's translated lyrics: one entry per original line (null for lines left as they are).
@immutable
class LyricsTranslation {
  const LyricsTranslation({required this.lines, this.sameLanguage = false, this.sourceLanguage});

  final List<String?> lines;

  /// The lyrics are already in the target language, so nothing is shown.
  final bool sameLanguage;

  final String? sourceLanguage;

  static const none = LyricsTranslation(lines: [], sameLanguage: true);

  String? operator [](int index) => sameLanguage || index >= lines.length ? null : lines[index];

  Map<String, Object?> toJson() => {"lines": lines, "same": sameLanguage, "source": sourceLanguage};

  factory LyricsTranslation.fromJson(Map<String, dynamic> json) => LyricsTranslation(
    lines: [for (final l in json["lines"] as List) l as String?],
    sameLanguage: json["same"] as bool? ?? false,
    sourceLanguage: json["source"] as String?,
  );
}

class LyricsTranslationException implements Exception {
  LyricsTranslationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Translates lyrics through LibreTranslate or DeepL and remembers the result per track, so a song is only sent once
/// per target language. Also stores the per-song "hide translation" choice.
class LyricsTranslationService {
  LyricsTranslationService({http.Client? client, Box<String>? box}) : _client = client, _testBox = box;

  static final instance = LyricsTranslationService();

  static const boxName = "LyricsTranslation";
  static const _configKey = "config";

  static final _log = Logger("LyricsTranslation");

  final http.Client? _client;
  final Box<String>? _testBox;

  static Future<void> open() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox<String>(boxName);
  }

  Box<String>? get _box => _testBox ?? (Hive.isBoxOpen(boxName) ? Hive.box<String>(boxName) : null);

  /// Rebuilds when the config or a per-song choice changes.
  ValueListenable<Box<String>>? listenable({List<String>? keys}) => _box?.listenable(keys: keys);

  LyricsTranslationConfig get config {
    final raw = _box?.get(_configKey);
    if (raw == null) return const LyricsTranslationConfig();
    try {
      return LyricsTranslationConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const LyricsTranslationConfig();
    }
  }

  Future<void> setConfig(LyricsTranslationConfig config) async => _box?.put(_configKey, jsonEncode(config.toJson()));

  static String hiddenKey(String trackId) => "hide:$trackId";

  /// Whether the user turned translation off for this track.
  bool isHidden(String trackId) => _box?.get(hiddenKey(trackId)) == "1";

  Future<void> setHidden(String trackId, bool hidden) async {
    final box = _box;
    if (box == null) return;
    hidden ? await box.put(hiddenKey(trackId), "1") : await box.delete(hiddenKey(trackId));
  }

  /// Removes every cached translation (the config and per-song choices stay).
  Future<void> clearCache() async {
    final box = _box;
    if (box == null) return;
    await box.deleteAll(box.keys.where((k) => "$k".startsWith("t:")).toList());
  }

  /// Cache key: the lyrics' text is part of it, so picking other lyrics for the track translates those.
  @visibleForTesting
  static String cacheKey(String trackId, List<String?> lines, String target, LyricsTranslationProvider provider) {
    final digest = sha1.convert(utf8.encode(lines.map((l) => l ?? "").join("\n"))).toString().substring(0, 16);
    return "t:$trackId:${provider.id}:$target:$digest";
  }

  LyricsTranslation? cached(String trackId, List<String?> lines, String target, {LyricsTranslationConfig? config}) {
    final raw = _box?.get(cacheKey(trackId, lines, target, (config ?? this.config).provider));
    if (raw == null) return null;
    try {
      return LyricsTranslation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Translation of [lines] into [target] (ISO 639-1), from the cache or the configured provider. Repeated lines
  /// (choruses) are only sent once.
  Future<LyricsTranslation> translate({
    required String trackId,
    required List<String?> lines,
    required String target,
    LyricsTranslationConfig? config,
  }) async {
    final cfg = config ?? this.config;
    final hit = cached(trackId, lines, target, config: cfg);
    if (hit != null) return hit;
    if (!cfg.isUsable) throw LyricsTranslationException("Translation isn't set up");

    final LyricsTranslation result;
    if (scriptRulesOut(lines, target)) {
      result = LyricsTranslation(lines: const [], sameLanguage: true, sourceLanguage: target);
    } else {
      final unique = <String>[];
      final indexOf = <String, int>{};
      for (final line in lines) {
        final text = line?.trim() ?? "";
        if (text.isEmpty || !RegExp(r"\p{L}", unicode: true).hasMatch(text)) continue;
        indexOf.putIfAbsent(text, () {
          unique.add(text);
          return unique.length - 1;
        });
      }
      if (unique.isEmpty) {
        result = LyricsTranslation.none;
      } else {
        final (translated, source) = await _request(cfg, unique, target);
        final same = source != null && _base(source) == _base(target);
        result = LyricsTranslation(
          sameLanguage: same,
          sourceLanguage: source,
          lines: same
              ? const []
              : [
                  for (final line in lines)
                    switch (indexOf[line?.trim() ?? ""]) {
                      final int i when translated[i].trim() != line!.trim() => translated[i],
                      _ => null,
                    },
                ],
        );
      }
    }
    await _box?.put(cacheKey(trackId, lines, target, cfg.provider), jsonEncode(result.toJson()));
    return result;
  }

  static String _base(String language) => language.toLowerCase().split(RegExp("[-_]")).first;

  /// Lyrics written in a script only [target] uses need no request: Japanese with kana into Japanese, Korean with
  /// Hangul into Korean.
  @visibleForTesting
  static bool scriptRulesOut(List<String?> lines, String target) {
    final text = lines.whereType<String>().join();
    bool any(int from, int to) => text.runes.any((c) => c >= from && c <= to);
    return switch (_base(target)) {
      "ja" => any(0x3040, 0x30FF),
      "ko" => any(0xAC00, 0xD7AF),
      _ => false,
    };
  }

  Future<(List<String>, String?)> _request(LyricsTranslationConfig cfg, List<String> texts, String target) async {
    final client = _client ?? http.Client();
    try {
      return switch (cfg.provider) {
        LyricsTranslationProvider.libreTranslate => await _libreTranslate(client, cfg, texts, target),
        LyricsTranslationProvider.deepl => await _deepl(client, cfg, texts, target),
      };
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<(List<String>, String?)> _libreTranslate(
    http.Client client,
    LyricsTranslationConfig cfg,
    List<String> texts,
    String target,
  ) async {
    var base = cfg.url.trim();
    while (base.endsWith("/")) {
      base = base.substring(0, base.length - 1);
    }
    final response = await client
        .post(
          Uri.parse("$base/translate"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "q": texts,
            "source": "auto",
            "target": libreTranslateCode(target),
            "format": "text",
            if (cfg.apiKey.trim().isNotEmpty) "api_key": cfg.apiKey.trim(),
          }),
        )
        .timeout(const Duration(seconds: 30));
    final body = _decode(response, "LibreTranslate");
    final translated = body["translatedText"];
    final List<String> out = translated is List ? [for (final t in translated) "$t"] : ["$translated"];
    if (out.length != texts.length) throw LyricsTranslationException("LibreTranslate returned ${out.length} lines");
    // A list of detections for a list of texts; the most confident one stands for the song.
    final detected = body["detectedLanguage"];
    String? source;
    if (detected is Map) {
      source = detected["language"] as String?;
    } else if (detected is List && detected.isNotEmpty) {
      final counts = <String, int>{};
      for (final d in detected.whereType<Map<dynamic, dynamic>>()) {
        final language = d["language"] as String?;
        if (language != null) counts[language] = (counts[language] ?? 0) + 1;
      }
      if (counts.isNotEmpty) source = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }
    return (out, source);
  }

  Future<(List<String>, String?)> _deepl(
    http.Client client,
    LyricsTranslationConfig cfg,
    List<String> texts,
    String target,
  ) async {
    final key = cfg.apiKey.trim();
    final host = key.endsWith(":fx") ? "api-free.deepl.com" : "api.deepl.com";
    final out = <String>[];
    final sources = <String, int>{};
    // DeepL takes at most 50 texts per request.
    for (var i = 0; i < texts.length; i += 50) {
      final chunk = texts.sublist(i, i + 50 > texts.length ? texts.length : i + 50);
      final response = await client
          .post(
            Uri.https(host, "/v2/translate"),
            headers: {"Authorization": "DeepL-Auth-Key $key", "Content-Type": "application/json"},
            body: jsonEncode({"text": chunk, "target_lang": deeplCode(target)}),
          )
          .timeout(const Duration(seconds: 30));
      final body = _decode(response, "DeepL");
      for (final t in body["translations"] as List) {
        final map = t as Map;
        out.add("${map["text"]}");
        final source = map["detected_source_language"] as String?;
        if (source != null) sources[source] = (sources[source] ?? 0) + 1;
      }
    }
    if (out.length != texts.length) throw LyricsTranslationException("DeepL returned ${out.length} lines");
    final source = sources.isEmpty ? null : sources.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    return (out, source?.toLowerCase());
  }

  Map<String, dynamic> _decode(http.Response response, String service) {
    if (response.statusCode != 200) {
      String detail = "";
      try {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is Map) detail = "${body["error"] ?? body["message"] ?? ""}";
      } catch (_) {}
      _log.warning("$service answered ${response.statusCode} $detail");
      throw LyricsTranslationException(switch (response.statusCode) {
        401 || 403 => "$service refused the API key",
        429 || 456 => "$service quota exceeded",
        _ => "$service error ${response.statusCode}${detail.isEmpty ? "" : ": $detail"}",
      });
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// DeepL wants regional English and Portuguese and a script for Chinese.
  @visibleForTesting
  static String deeplCode(String language) => switch (_base(language)) {
    "en" => "EN-US",
    "pt" => language.toUpperCase().replaceAll("_", "-") == "PT-PT" ? "PT-PT" : "PT-BR",
    "zh" => language.toLowerCase().contains("hant") ? "ZH-HANT" : "ZH-HANS",
    final base => base.toUpperCase(),
  };

  @visibleForTesting
  static String libreTranslateCode(String language) => switch (_base(language)) {
    "zh" => language.toLowerCase().contains("hant") ? "zt" : "zh",
    final base => base,
  };
}
