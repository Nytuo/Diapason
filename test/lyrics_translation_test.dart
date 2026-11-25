import 'dart:convert';
import 'dart:io';

import 'package:diapason/services/lyrics/lyrics_translation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory dir;
  late Box<String> box;
  late List<http.Request> requests;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync("lyrics_translation");
    Hive.init(dir.path);
    box = await Hive.openBox<String>("t${DateTime.now().microsecondsSinceEpoch}");
    requests = [];
  });

  tearDown(() async {
    await box.close();
    dir.deleteSync(recursive: true);
  });

  MockClient libre({String detected = "fr"}) => MockClient((request) async {
    requests.add(request);
    final q = (jsonDecode(request.body) as Map)["q"] as List;
    return http.Response(
      jsonEncode({
        "translatedText": [for (final t in q) "EN($t)"],
        "detectedLanguage": [
          for (final _ in q) {"language": detected, "confidence": 90},
        ],
      }),
      200,
      headers: {"content-type": "application/json"},
    );
  });

  const libreConfig = LyricsTranslationConfig(url: "https://lt.example.org/");
  const lines = ["Bonjour", "", "Le refrain", "Le refrain", null, "123"];

  test("translates unique lines once and caches per track", () async {
    final service = LyricsTranslationService(client: libre(), box: box);
    await service.setConfig(libreConfig);

    final first = await service.translate(trackId: "a", lines: lines, target: "en");
    expect(first.sameLanguage, isFalse);
    expect(first.sourceLanguage, "fr");
    expect(first.lines, ["EN(Bonjour)", null, "EN(Le refrain)", "EN(Le refrain)", null, null]);
    expect(requests, hasLength(1));
    expect(requests.single.url.toString(), "https://lt.example.org/translate");
    expect((jsonDecode(requests.single.body) as Map)["q"], ["Bonjour", "Le refrain"]);

    final again = await service.translate(trackId: "a", lines: lines, target: "en");
    expect(again.lines, first.lines);
    expect(requests, hasLength(1), reason: "second call is served from the cache");

    // Another target language, or other lyrics for the track, are new requests.
    await service.translate(trackId: "a", lines: lines, target: "de");
    await service.translate(trackId: "a", lines: [...lines, "Encore"], target: "en");
    expect(requests, hasLength(3));

    await service.clearCache();
    expect(service.cached("a", lines, "en"), isNull);
    expect(service.config, libreConfig, reason: "clearing the cache keeps the config");
  });

  test("same language is remembered and shows nothing", () async {
    final service = LyricsTranslationService(
      client: libre(detected: "en"),
      box: box,
    );
    final result = await service.translate(trackId: "b", lines: ["Hello"], target: "en", config: libreConfig);
    expect(result.sameLanguage, isTrue);
    expect(result[0], isNull);
    expect(service.cached("b", ["Hello"], "en", config: libreConfig)!.sameLanguage, isTrue);
  });

  test("Japanese into Japanese is skipped without a request", () async {
    final service = LyricsTranslationService(client: libre(), box: box);
    final result = await service.translate(trackId: "c", lines: ["君の名は"], target: "ja", config: libreConfig);
    expect(result.sameLanguage, isTrue);
    expect(requests, isEmpty);
  });

  test("errors are not cached", () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(jsonEncode({"error": "Invalid API key"}), 403);
    });
    final service = LyricsTranslationService(client: client, box: box);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        service.translate(trackId: "d", lines: ["Hola"], target: "en", config: libreConfig),
        throwsA(isA<LyricsTranslationException>()),
      );
    }
    expect(calls, 2);
  });

  test("DeepL: free keys use the free host, regional targets", () async {
    final client = MockClient((request) async {
      requests.add(request);
      expect(request.headers["Authorization"], "DeepL-Auth-Key abc:fx");
      final text = (jsonDecode(request.body) as Map)["text"] as List;
      return http.Response(
        jsonEncode({
          "translations": [
            for (final t in text) {"text": "[$t]", "detected_source_language": "DE"},
          ],
        }),
        200,
      );
    });
    final service = LyricsTranslationService(client: client, box: box);
    final result = await service.translate(
      trackId: "e",
      lines: ["Hallo"],
      target: "en",
      config: const LyricsTranslationConfig(provider: LyricsTranslationProvider.deepl, apiKey: "abc:fx"),
    );
    expect(result[0], "[Hallo]");
    expect(result.sourceLanguage, "de");
    expect(requests.single.url.host, "api-free.deepl.com");
    expect((jsonDecode(requests.single.body) as Map)["target_lang"], "EN-US");
    expect(LyricsTranslationService.deeplCode("pt_PT"), "PT-PT");
    expect(LyricsTranslationService.deeplCode("zh"), "ZH-HANS");
    expect(LyricsTranslationService.libreTranslateCode("zh_Hant"), "zt");
  });

  test("per-song hide toggle", () async {
    final service = LyricsTranslationService(box: box);
    expect(service.isHidden("x"), isFalse);
    await service.setHidden("x", true);
    expect(service.isHidden("x"), isTrue);
    await service.setHidden("x", false);
    expect(service.isHidden("x"), isFalse);
  });

  test("config needs a server or a key", () {
    expect(const LyricsTranslationConfig().isUsable, isFalse);
    expect(libreConfig.isUsable, isTrue);
    expect(const LyricsTranslationConfig(provider: LyricsTranslationProvider.deepl).isUsable, isFalse);
  });
}
