import 'dart:convert';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:diapason/services/lyrics/lrclib_client.dart';
import 'package:diapason/services/lyrics/word_sync_parser.dart';
import 'package:diapason/services/lyrics/word_synced_lyrics_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

int ms(int millis) => millis * 10000; // ticks

String wordsOf(LyricLine line) =>
    line.cues!.map((c) => line.text!.substring(c.position, c.endPosition)).join("|");

void main() {
  group("TTML (AMLL / Apple Music style)", () {
    const ttml =
        '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">'
        '<body dur="3:30.000"><div>'
        '<p begin="00:10.000" end="00:12.500">'
        '<span begin="00:10.000" end="00:10.400">Look</span> '
        '<span begin="00:10.400" end="00:10.900">at</span> '
        '<span begin="00:10.900" end="00:12.500">the stars</span>'
        '<span ttm:role="x-bg"><span begin="00:11.000" end="00:11.500">(ooh)</span></span>'
        '<span ttm:role="x-translation">Regarde</span>'
        '</p>'
        '<p begin="1:02.250" end="1:03.000"><span begin="1:02.250" end="1:03.000">Yellow</span></p>'
        '</div></body></tt>';

    test("lines and words keep their timing, positions point into the line", () {
      final lyrics = WordSyncParser.parseTtml(ttml)!;
      final first = lyrics.lyrics!.first;

      expect(first.text, "Look at the stars");
      expect(first.start, ms(10000));
      expect(wordsOf(first), "Look|at|the stars");
      expect(first.cues![1].start, ms(10400));
      expect(first.cues![1].end, ms(10900));

      expect(lyrics.lyrics![1].start, ms(62250));
      expect(WordSyncParser.hasWordCues(lyrics), isTrue);
    });

    test("background vocals and translations stay out of the main line", () {
      final first = WordSyncParser.parseTtml(ttml)!.lyrics!.first;
      expect(first.text, isNot(contains("ooh")));
      expect(first.text, isNot(contains("Regarde")));
    });

    test("broken XML gives no lyrics instead of throwing", () {
      expect(WordSyncParser.parseTtml("<tt><body>"), isNull);
    });

    test("time formats", () {
      expect(WordSyncParser.parseTtmlTime("1:02.345"), const Duration(minutes: 1, seconds: 2, milliseconds: 345));
      expect(WordSyncParser.parseTtmlTime("00:01:02.345"), const Duration(minutes: 1, seconds: 2, milliseconds: 345));
      expect(WordSyncParser.parseTtmlTime("62.5s"), const Duration(seconds: 62, milliseconds: 500));
      expect(WordSyncParser.parseTtmlTime("250ms"), const Duration(milliseconds: 250));
    });
  });

  group("Enhanced LRC", () {
    test("inline word stamps become cues; plain LRC is untouched", () {
      final lyrics = LrcParser.parse("[00:12.00]<00:12.00>Word <00:12.50>by <00:12.80>word<00:13.40>\n[00:14.00]Plain")!;
      final first = lyrics.lyrics!.first;
      expect(first.text, "Word by word");
      expect(wordsOf(first), "Word|by|word");
      expect(first.cues!.last.end, ms(13400));
      expect(lyrics.lyrics![1].text, "Plain");
      expect(lyrics.lyrics![1].cues, isNull);

      expect(WordSyncParser.hasWordCues(LrcParser.parse("[00:01.00]Only lines")), isFalse);
    });
  });

  group("NetEase YRC", () {
    test("parses words and skips credit lines", () {
      final lyrics = WordSyncParser.parseYrc(
        '{"t":0,"c":[{"tx":"作词: "}]}\n[33520,2520](33520,420,0)Look (33940,270,0)at (34210,120,0)the',
      )!;
      final line = lyrics.lyrics!.single;
      expect(line.text, "Look at the");
      expect(line.start, ms(33520));
      expect(wordsOf(line), "Look|at|the");
      expect(line.cues!.first.end, ms(33940));
    });
  });

  group("WordSyncedLyricsClient", () {
    test("titles compare loosely", () {
      expect(
        WordSyncedLyricsClient.normalise("Yellow (Remastered 2011) - Live"),
        WordSyncedLyricsClient.normalise("yellow"),
      );
      expect(WordSyncedLyricsClient.normalise("Song feat. Someone"), WordSyncedLyricsClient.normalise("Song"));
    });

    test("NetEase: only a matching title, artist and length is used", () async {
      final client = WordSyncedLyricsClient(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith("/cloudsearch/pc")) {
            return http.Response(
              jsonEncode({
                "result": {
                  "songs": [
                    {"id": 1, "name": "Yellow", "dt": 400000, "ar": [{"name": "Coldplay"}]},
                    {"id": 2, "name": "Yellow", "dt": 266773, "ar": [{"name": "Coldplay"}]},
                  ],
                },
              }),
              200,
            );
          }
          expect(request.url.queryParameters["id"], "2");
          return http.Response(
            jsonEncode({
              "yrc": {"lyric": "[1000,500](1000,500,0)Hi"},
            }),
            200,
          );
        }),
      );

      final lyrics = await client.fetch(
        title: "Yellow",
        artists: ["Coldplay"],
        duration: const Duration(seconds: 267),
        amll: false,
        netease: true,
      );
      expect(lyrics!.lyrics!.single.text, "Hi");
    });
  });

  group("Lyricsfile (LRCLIB)", () {
    const wordSynced = """
version: "1.0"
metadata:
  title: Still Alive
  artist: Aperture Science
lines:
  - text: This was a triumph.
    start_ms: 290
    end_ms: 3840
    words:
      - text: "This "
        start_ms: 290
      - text: "was "
        start_ms: 536
      - text: triumph.
        start_ms: 923
  - text: Line only
    start_ms: 4000
plain: |
  This was a triumph.
""";

    test("words become cues; the last word ends with its line", () {
      final lyrics = WordSyncParser.parseLyricsfile(wordSynced)!;
      final first = lyrics.lyrics!.first;
      expect(first.text, "This was triumph.");
      expect(wordsOf(first), "This|was|triumph.");
      expect(first.start, ms(290));
      expect(first.cues!.last.end, ms(3840));
      expect(lyrics.lyrics![1].cues, isNull);
      expect(lyrics.lyrics![1].start, ms(4000));
    });

    test("plain-only, instrumental and other versions", () {
      expect(
        WordSyncParser.parseLyricsfile('version: "1.0"\nmetadata: {title: a, artist: b}\nplain: |\n  One\n  Two\n')!
            .lyrics!
            .map((l) => l.text),
        ["One", "Two"],
      );
      expect(WordSyncParser.parseLyricsfile('version: "1.0"\nmetadata: {title: a, artist: b, instrumental: true}'), isNull);
      expect(WordSyncParser.parseLyricsfile('version: "2.0"\nmetadata: {title: a, artist: b}\nplain: x'), isNull);
      expect(WordSyncParser.parseLyricsfile("not: [valid"), isNull);
    });

    test("LRCLIB prefers an upload with word sync over the exact match without it", () async {
      final client = LrclibClient(
        httpClient: MockClient((request) async {
          if (request.url.path == "/api/get") {
            return http.Response(jsonEncode({"duration": 176, "syncedLyrics": "[00:01.00]Line synced", "hasWordSync": false}), 200);
          }
          return http.Response(
            jsonEncode([
              {"duration": 300, "hasWordSync": true, "lyricsfile": wordSynced},
              {"duration": 176.4, "hasWordSync": true, "lyricsfile": wordSynced, "syncedLyrics": "[00:01.00]x"},
            ]),
            200,
          );
        }),
      );
      final lyrics = await client.fetch(title: "Still Alive", artist: "Aperture", duration: const Duration(seconds: 176));
      expect(WordSyncParser.hasWordCues(lyrics), isTrue);
    });

    test("a word-synced upload a few seconds shorter still wins over a closer line-synced one", () async {
      // The real Still Alive case: the word-synced upload says 176 s, a 2:59 rip is 179 s.
      final client = LrclibClient(
        httpClient: MockClient((request) async {
          if (request.url.path == "/api/get") return http.Response("", 404);
          return http.Response(
            jsonEncode([
              {"duration": 177.0, "hasWordSync": false, "syncedLyrics": "[00:01.00]Line synced"},
              {"duration": 176.0, "hasWordSync": true, "lyricsfile": wordSynced},
            ]),
            200,
          );
        }),
      );
      final lyrics = await client.fetch(title: "Still Alive", artist: "Aperture", duration: const Duration(milliseconds: 179400));
      expect(WordSyncParser.hasWordCues(lyrics), isTrue);
    });
  });
}
