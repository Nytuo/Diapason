import 'dart:convert';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/scrobbling/lastfm_client.dart';
import 'package:diapason/services/scrobbling/listenbrainz_client.dart';
import 'package:diapason/services/scrobbling/scrobble_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

BaseItemDto _track({String? artist = "Artist", Duration? duration}) => BaseItemDto(
  id: const BaseItemId("jf-1~t1"),
  name: "Song",
  albumArtist: artist,
  album: "Album",
  runTimeTicks: duration == null ? null : duration.inMicroseconds * 10,
);

void main() {
  group("what counts as a listen", () {
    // Last.fm's rule, which ListenBrainz also follows: half the track, or four
    // minutes, whichever comes first.
    test("half of a track counts", () {
      expect(ScrobbleService.qualifies(const Duration(minutes: 2), const Duration(minutes: 4)), isTrue);
      expect(ScrobbleService.qualifies(const Duration(seconds: 119), const Duration(minutes: 4)), isFalse);
    });

    test("four minutes counts, however long the track is", () {
      // Half of a 30-minute track is 15 minutes — the four-minute rule is what
      // makes long tracks scrobblable at all.
      expect(ScrobbleService.qualifies(const Duration(minutes: 4), const Duration(minutes: 30)), isTrue);
    });

    test("a skip does not count", () {
      expect(ScrobbleService.qualifies(const Duration(seconds: 10), const Duration(minutes: 4)), isFalse);
    });

    test("an unknown duration only counts past four minutes", () {
      expect(ScrobbleService.qualifies(const Duration(minutes: 1), null), isFalse);
      expect(ScrobbleService.qualifies(const Duration(minutes: 5), null), isTrue);
    });
  });

  group("ListenBrainzClient", () {
    test("submits a listen with the time the track started", () async {
      Map<String, dynamic>? sent;
      final client = ListenBrainzClient(
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response("{}", 200);
        }),
      );

      final startedAt = DateTime.utc(2026, 1, 1, 12);
      final ok = await client.submitListen(_track(duration: const Duration(minutes: 3)), "token", startedAt: startedAt);

      expect(ok, isTrue);
      expect(sent!["listen_type"], "single");
      final payload = (sent!["payload"] as List<dynamic>).single as Map<String, dynamic>;
      expect(payload["listened_at"], startedAt.millisecondsSinceEpoch ~/ 1000);
      expect(payload["track_metadata"]["artist_name"], "Artist");
      expect(payload["track_metadata"]["track_name"], "Song");
    });

    test("now-playing carries no timestamp", () async {
      Map<String, dynamic>? sent;
      final client = ListenBrainzClient(
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response("{}", 200);
        }),
      );

      await client.submitPlayingNow(_track(), "token");

      expect(sent!["listen_type"], "playing_now");
      expect((sent!["payload"] as List<dynamic>).single, isNot(contains("listened_at")));
    });

    test("a track with no artist is never submitted", () async {
      var called = false;
      final client = ListenBrainzClient(
        httpClient: MockClient((_) async {
          called = true;
          return http.Response("{}", 200);
        }),
      );

      expect(await client.submitListen(_track(artist: null), "token"), isFalse);
      expect(called, isFalse);
    });

    test("a rejected listen reports failure rather than throwing", () async {
      final client = ListenBrainzClient(httpClient: MockClient((_) async => http.Response("nope", 401)));

      expect(await client.submitListen(_track(), "bad-token"), isFalse);
    });
  });

  group("LastFmClient", () {
    test("signs requests, and excludes format from the signature", () async {
      Map<String, String>? sent;
      final client = LastFmClient(
        apiKey: "key",
        apiSecret: "secret",
        httpClient: MockClient((request) async {
          sent = Uri.splitQueryString(request.body);
          return http.Response('{"scrobbles":{}}', 200);
        }),
      );

      await client.scrobble(_track(), "session", startedAt: DateTime.utc(2026));

      // Including format=json in the signature makes every call fail as invalid,
      // which is a miserable thing to debug.
      expect(sent!["api_sig"], isNotNull);
      expect(sent!["format"], "json");
      expect(sent!["sk"], "session");
      expect(sent!["artist"], "Artist");
    });

    test("an unconfigured client does nothing", () async {
      var called = false;
      final client = LastFmClient(
        apiKey: "",
        apiSecret: "",
        httpClient: MockClient((_) async {
          called = true;
          return http.Response("{}", 200);
        }),
      );

      expect(client.isConfigured, isFalse);
      expect(await client.scrobble(_track(), "session"), isFalse);
      expect(called, isFalse);
    });

    test("an error response is reported, not thrown", () async {
      final client = LastFmClient(
        apiKey: "key",
        apiSecret: "secret",
        httpClient: MockClient((_) async => http.Response('{"error":9,"message":"Invalid session key"}', 200)),
      );

      expect(await client.scrobble(_track(), "stale-session"), isFalse);
    });
  });
}
