import 'dart:convert';
import 'dart:io';

import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/match/acoustid.dart';
import 'package:diapason/services/tag_editor/match/cover_search.dart';
import 'package:diapason/services/tag_editor/match/lookup_http.dart';
import 'package:diapason/services/tag_editor/match/match_scoring.dart';
import 'package:diapason/services/tag_editor/match/musicbrainz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Fixtures are real API responses (trimmed), except the AcoustID one which
/// follows the documented format (lookups need an application key).
dynamic fixture(String name) => jsonDecode(File("test/tag_editor/fixtures/$name").readAsStringSync());

void main() {
  const digitalLove = MatchQuery(
    title: "Digital Love",
    artists: ["Daft Punk"],
    album: "Discovery",
    duration: Duration(milliseconds: 301000),
  );

  group("scoring", () {
    test("similarity normalises case, accents, punctuation and brackets", () {
      expect(MatchScoring.similarity("Beyoncé", "beyonce"), 1);
      expect(MatchScoring.similarity("Song (Remastered 2011)", "Song"), closeTo(0.95, 0.001));
      expect(MatchScoring.similarity("Rock & Roll", "Rock and Roll"), 1);
      expect(MatchScoring.similarity("Completely different", "Nothing alike"), lessThan(0.4));
    });

    test("duration score is flat within 2s and zero past 15s", () {
      expect(MatchScoring.durationScore(const Duration(seconds: 200), const Duration(seconds: 201)), 1);
      expect(MatchScoring.durationScore(const Duration(seconds: 200), const Duration(seconds: 230)), 0);
      expect(
        MatchScoring.durationScore(const Duration(seconds: 200), const Duration(milliseconds: 208500)),
        closeTo(0.5, 0.01),
      );
      expect(MatchScoring.durationScore(null, const Duration(seconds: 3)), isNull);
    });

    test("weighted ignores unknown components", () {
      expect(MatchScoring.weighted([(1, 0.5), (null, 0.5)]), 1);
      expect(MatchScoring.weighted([(1, 0.5), (0, 0.5)]), 0.5);
    });
  });

  group("MusicBrainz parsing", () {
    test("recording search ranks the album version first using duration", () {
      final results = MusicBrainzClient.parseRecordingSearch(fixture("mb_recording_search.json"), digitalLove);
      expect(results, isNotEmpty);
      final best = results.first;
      // MB's own score puts a remix first; title + duration matching must not.
      expect(best.title, anyOf("Digital Love", "Digital Love (album version)"));
      expect(best.confidence, greaterThan(0.85));
      expect(best.bestRelease?.title, "Discovery");
      expect(best.artists.first.name, "Daft Punk");
      final remix = results.firstWhere((r) => r.title.contains("Algeronics"));
      expect(remix.confidence, lessThan(best.confidence));
    });

    test("release search scores track count", () {
      final results = MusicBrainzClient.parseReleaseSearch(
        fixture("mb_release_search.json"),
        const MatchQuery(album: "Discovery", albumArtists: ["Daft Punk"]),
        trackCount: 14,
        year: 2001,
      );
      expect(results.first.title, "Discovery");
      expect(results.first.trackCount, 14);
      expect(results.first.date, startsWith("2001"));
      expect(results.first.confidence, greaterThan(0.9));
    });

    test("release lookup applies album and track fields", () {
      final release = MbRelease.parse(fixture("mb_release_lookup.json") as Map<String, dynamic>);
      expect(release.title, "Discovery");
      expect(release.tracks.length, 14);
      final track = release.tracks.firstWhere((t) => t.title == "Digital Love");

      final tags = AudioTags(
        values: {
          TagField.comment: ["kept"],
        },
      );
      release.applyTrack(tags, track);
      expect(tags[TagField.title], "Digital Love");
      expect(tags[TagField.album], "Discovery");
      expect(tags.all(TagField.albumArtists), ["Daft Punk"]);
      expect(tags[TagField.trackNumber], "3");
      expect(tags[TagField.trackTotal], "14");
      expect(tags[TagField.discNumber], "1");
      expect(tags[TagField.musicBrainzReleaseId], release.id);
      expect(tags[TagField.musicBrainzRecordingId], track.recordingId);
      expect(tags[TagField.musicBrainzReleaseTrackId], track.id);
      expect(tags.all(TagField.musicBrainzArtistIds), ["056e4f3e-d505-4dad-8ec1-d04f521cbb56"]);
      expect(tags[TagField.comment], "kept");
    });

    test("track mapping uses numbers, then titles, then order", () {
      final release = MbRelease.parse(fixture("mb_release_lookup.json") as Map<String, dynamic>);
      final mapped = release.mapTracks([
        (title: "One More Time", disc: 1, track: 1, duration: null),
        (title: "digital love", disc: null, track: null, duration: null),
        (title: "Aerodynamic", disc: 1, track: 9, duration: null), // wrong number, right title
        (title: "Something else entirely", disc: null, track: null, duration: null),
      ]);
      expect(mapped[0]?.title, "One More Time");
      expect(mapped[1]?.title, "Digital Love");
      expect(mapped[2]?.title, "Aerodynamic");
      expect(mapped[3], isNull);
    });
  });

  group("cover sources", () {
    test("Cover Art Archive puts the front first and uses https", () {
      final covers = CoverSearch.parseCoverArtArchive(fixture("caa_release.json"));
      expect(covers, isNotEmpty);
      expect(covers.first.imageUrl.scheme, "https");
      expect(covers.first.source, CoverSource.coverArtArchive);
    });

    test("iTunes artwork is upsized to 3000px", () {
      final covers = CoverSearch.parseItunes(fixture("itunes_album_search.json"));
      expect(covers, isNotEmpty);
      expect(covers.first.imageUrl.path, contains("3000x3000bb"));
      expect(covers.first.thumbnailUrl.path, contains("300x300bb"));
      expect(covers.first.artist, "Daft Punk");
    });

    test("Deezer uses cover_xl", () {
      final covers = CoverSearch.parseDeezer(fixture("deezer_album_search.json"));
      expect(covers, isNotEmpty);
      expect(covers.first.imageUrl.path, contains("1000x1000"));
      expect(covers.first.title, "Discovery");
    });

    test("a failing source doesn't hide the others", () async {
      final client = MockClient((request) async {
        if (request.url.host == "itunes.apple.com") return http.Response("nope", 500);
        if (request.url.host == "api.deezer.com") {
          return http.Response(jsonEncode(fixture("deezer_album_search.json")), 200);
        }
        return http.Response("{}", 404);
      });
      final search = CoverSearch(LookupHttp(client: client, version: "test"));
      final covers = await search.search(album: "Discovery", artist: "Daft Punk");
      expect(covers.map((c) => c.source).toSet(), {CoverSource.deezer});
    });
  });

  group("HTTP", () {
    test("sends the Diapason User-Agent and spaces MusicBrainz calls", () async {
      final times = <DateTime>[];
      final client = MockClient((request) async {
        expect(request.headers["User-Agent"], "Diapason/1.2.3 ( https://github.com/Nytuo/diapason )");
        times.add(DateTime.now());
        return http.Response(jsonEncode({"recordings": <Object>[]}), 200);
      });
      final mb = MusicBrainzClient(LookupHttp(client: client, version: "1.2.3"));
      await Future.wait([
        mb.searchRecordings(const MatchQuery(title: "a")),
        mb.searchRecordings(const MatchQuery(title: "b")),
      ]);
      expect(times.length, 2);
      expect(times[1].difference(times[0]).inMilliseconds, greaterThanOrEqualTo(1000));
    });

    test("retries once on 503", () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return calls == 1 ? http.Response("busy", 503) : http.Response(jsonEncode({"releases": <Object>[]}), 200);
      });
      final lookup = LookupHttp(client: client, version: "t")..retryDelay = Duration.zero;
      final results = await MusicBrainzClient(lookup).searchReleases(const MatchQuery(album: "x"));
      expect(results, isEmpty);
      expect(calls, 2);
    });
  });

  test("AcoustID lookup results are sorted by score", () {
    final matches = AcoustIdClient.parseLookup({
      "status": "ok",
      "results": [
        {
          "id": "a",
          "score": 0.4,
          "recordings": [
            {"id": "r1"},
          ],
        },
        {
          "id": "b",
          "score": 0.97,
          "recordings": [
            {"id": "r2"},
            {"id": "r3"},
          ],
        },
        {"id": "c", "score": 0.99},
      ],
    });
    expect(matches.map((m) => m.recordingIds), [
      ["r2", "r3"],
      ["r1"],
    ]);
  });
}
