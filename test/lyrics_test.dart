import 'dart:convert';

import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:diapason/services/lyrics/lrclib_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Serves canned LRCLIB responses, recording what was asked for.
MockClient _lrclib({Map<String, dynamic>? exact, List<Map<String, dynamic>>? search, List<String>? seen}) {
  return MockClient((request) async {
    seen?.add(request.url.path);
    if (request.url.path == "/api/get") {
      if (exact == null) return http.Response("Not Found", 404);
      return http.Response(jsonEncode(exact), 200);
    }
    if (request.url.path == "/api/search") {
      return http.Response(jsonEncode(search ?? const []), 200);
    }
    return http.Response("Not Found", 404);
  });
}

const _synced = {"syncedLyrics": "[00:10.00]Timed line", "plainLyrics": "Timed line"};
const _plainOnly = {"syncedLyrics": null, "plainLyrics": "Just words\nNo timings"};

void main() {
  group("LrcParser", () {
    test("isSynced only when a line carries a timing", () {
      expect(LrcParser.isSynced(LrcParser.parse("[00:01.00]x")), isTrue);
      expect(LrcParser.isSynced(LrcParser.plain("x")), isFalse);
      expect(LrcParser.isSynced(null), isFalse);
    });
  });

  group("LrclibClient", () {
    test("returns synced lyrics from the exact-match endpoint", () async {
      final client = LrclibClient(httpClient: _lrclib(exact: _synced));

      final lyrics = await client.fetch(title: "Song", artist: "Artist");

      expect(LrcParser.isSynced(lyrics), isTrue);
      expect(lyrics!.lyrics!.single.text, "Timed line");
    });

    test("falls back to search when the exact match 404s", () async {
      final seen = <String>[];
      // The exact endpoint 404s whenever metadata doesn't line up with theirs.
      final client = LrclibClient(httpClient: _lrclib(exact: null, search: [_synced], seen: seen));

      final lyrics = await client.fetch(title: "Song", artist: "Artist");

      expect(seen, ["/api/get", "/api/search"]);
      expect(LrcParser.isSynced(lyrics), isTrue);
    });


    test("a search result of a different length is a different song", () async {
      // Search matches loosely, so "Rivalry" by someone else, three minutes
      // longer, can come back. Wrong lyrics scrolling over the wrong song are
      // worse than no lyrics at all.
      final wrongSong = {...
        _synced,
        "duration": 400.0,
      };
      final client = LrclibClient(httpClient: _lrclib(exact: null, search: [wrongSong]));

      final lyrics = await client.fetch(
        title: "Song",
        artist: "Artist",
        duration: const Duration(seconds: 200),
      );

      expect(lyrics, isNull);
    });

    test("a couple of seconds of disagreement is still the same song", () async {
      // Encoders and taggers rarely agree to the second.
      final sameSong = {...
        _synced,
        "duration": 201.0,
      };
      final client = LrclibClient(httpClient: _lrclib(exact: null, search: [sameSong]));

      final lyrics = await client.fetch(
        title: "Song",
        artist: "Artist",
        duration: const Duration(seconds: 200),
      );

      expect(LrcParser.isSynced(lyrics), isTrue);
    });

    test("an unknown length is not a reason to reject the only result there is", () async {
      final client = LrclibClient(httpClient: _lrclib(exact: null, search: [_synced]));

      final lyrics = await client.fetch(title: "Song", artist: "Artist", duration: const Duration(seconds: 200));

      expect(LrcParser.isSynced(lyrics), isTrue, reason: "the result carries no duration to compare against");
    });

    test("syncedOnly refuses plain lyrics, so unsynced are never swapped for unsynced", () async {
      final client = LrclibClient(httpClient: _lrclib(exact: _plainOnly));

      // This is the rule: an upgrade must actually be an upgrade.
      expect(await client.fetch(title: "Song", artist: "Artist", syncedOnly: true), isNull);
      // Without that constraint the same response is perfectly usable.
      expect(await client.fetch(title: "Song", artist: "Artist"), isNotNull);
    });

    test("instrumental tracks report no lyrics", () async {
      final client = LrclibClient(
        httpClient: _lrclib(exact: {"instrumental": true, "syncedLyrics": null, "plainLyrics": null}),
      );

      expect(await client.fetch(title: "Song", artist: "Artist"), isNull);
    });

    test("a track with no artist is not looked up at all", () async {
      final seen = <String>[];
      final client = LrclibClient(httpClient: _lrclib(exact: _synced, seen: seen));

      expect(await client.fetch(title: "Song", artist: ""), isNull);
      expect(seen, isEmpty, reason: "no point asking LRCLIB without an artist");
    });

    test("a server error yields no lyrics rather than an exception", () async {
      final client = LrclibClient(httpClient: MockClient((_) async => http.Response("boom", 500)));

      expect(await client.fetch(title: "Song", artist: "Artist"), isNull);
    });
  });
}
