import 'dart:convert';

import 'package:diapason/models/radio_station.dart';
import 'package:diapason/services/radio/icy_metadata.dart';
import 'package:diapason/services/radio/radio_browser_client.dart';
import 'package:diapason/services/radio/radio_playlist.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _stationJson = '''
[
  {
    "changeuuid": "x",
    "stationuuid": "9617a958-0601-11e8-ae97-52543be04c81",
    "name": "  FIP  ",
    "url": "http://icecast.radiofrance.fr/fip-midfi.mp3",
    "url_resolved": "https://icecast.radiofrance.fr/fip-midfi.mp3",
    "homepage": "https://www.radiofrance.fr/fip",
    "favicon": "https://www.radiofrance.fr/fip.png",
    "tags": "eclectic, jazz,,world ",
    "country": "France",
    "countrycode": "FR",
    "language": "french",
    "votes": 12345,
    "codec": "MP3",
    "bitrate": 128,
    "hls": 0,
    "clickcount": "321"
  },
  {
    "stationuuid": "hls-1",
    "name": "HLS station",
    "url": "https://example.com/live/master.m3u8",
    "url_resolved": "",
    "codec": "UNKNOWN",
    "bitrate": 0,
    "hls": 1
  },
  {"stationuuid": "no-url", "name": "Broken", "url": ""},
  {"name": "No uuid", "url": "http://x"},
  "garbage"
]
''';

void main() {
  group("Radio Browser JSON", () {
    test("parses stations and skips invalid entries", () {
      final stations = RadioStation.listFromRadioBrowserJson(jsonDecode(_stationJson));
      expect(stations, hasLength(2));

      final fip = stations.first;
      expect(fip.id, "9617a958-0601-11e8-ae97-52543be04c81");
      expect(fip.name, "FIP");
      expect(fip.streamUrl, "https://icecast.radiofrance.fr/fip-midfi.mp3", reason: "url_resolved wins");
      expect(fip.tags, ["eclectic", "jazz", "world"]);
      expect(fip.countryCode, "FR");
      expect(fip.bitrate, 128);
      expect(fip.clickCount, 321);
      expect(fip.isHls, isFalse);
      expect(fip.isCustom, isFalse);
      expect(fip.formatLabel, "MP3 · 128 kbps");

      final hls = stations.last;
      expect(hls.streamUrl, "https://example.com/live/master.m3u8", reason: "empty url_resolved falls back to url");
      expect(hls.isHls, isTrue);
      expect(hls.formatLabel, "HLS");
    });

    test("non-list responses give no stations", () {
      expect(RadioStation.listFromRadioBrowserJson({"error": "x"}), isEmpty);
      expect(RadioStation.listFromRadioBrowserJson(null), isEmpty);
    });

    test("parses categories, servers and click responses", () {
      final countries = RadioBrowserCategory.listFromJson(
        jsonDecode('[{"name":"France","iso_3166_1":"FR","stationcount":1500},{"name":"","stationcount":3}]'),
        codeKey: "iso_3166_1",
      );
      expect(countries.single.name, "France");
      expect(countries.single.code, "FR");
      expect(countries.single.stationCount, 1500);

      expect(
        RadioBrowserClient.parseServers(
          jsonDecode(
            '[{"ip":"1","name":"de1.api.radio-browser.info"},{"ip":"2","name":"de1.api.radio-browser.info"},'
            '{"ip":"3","name":"fi1.api.radio-browser.info"}]',
          ),
        ),
        ["de1.api.radio-browser.info", "fi1.api.radio-browser.info"],
      );

      expect(
        RadioBrowserClient.parseClickUrl({"ok": true, "message": "retrieved station url", "url": "http://a.b/c"}),
        Uri.parse("http://a.b/c"),
      );
      expect(RadioBrowserClient.parseClickUrl({"ok": false, "url": "http://a.b/c"}), isNull);
    });

    test("search sends the filters and a Diapason User-Agent", () async {
      late http.Request seen;
      final client = RadioBrowserClient(
        client: MockClient((request) async {
          seen = request;
          return http.Response(_stationJson, 200);
        }),
        userAgent: "Diapason/1.2.3",
        servers: ["de1.api.radio-browser.info"],
      );
      final stations = await client.search(name: " fip ", countryCode: "FR", tag: "jazz");
      expect(stations, hasLength(2));
      expect(seen.url.host, "de1.api.radio-browser.info");
      expect(seen.url.path, "/json/stations/search");
      expect(seen.url.queryParameters, containsPair("name", "fip"));
      expect(seen.url.queryParameters, containsPair("countrycode", "FR"));
      expect(seen.url.queryParameters, containsPair("tag", "jazz"));
      expect(seen.url.queryParameters, containsPair("hidebroken", "true"));
      expect(seen.headers["User-Agent"], "Diapason/1.2.3");
    });

    test("a failing server falls back to the next one", () async {
      final hosts = <String>[];
      final client = RadioBrowserClient(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          return request.url.host == "bad.api.radio-browser.info"
              ? http.Response("oops", 503)
              : http.Response("[]", 200);
        }),
        userAgent: "Diapason/1",
        servers: ["bad.api.radio-browser.info", "good.api.radio-browser.info"],
      );
      // The first server is picked at random; make sure both orders succeed.
      for (var i = 0; i < 5; i++) {
        expect(await client.top(), isEmpty);
      }
      expect(hosts, contains("good.api.radio-browser.info"));
    });

    test("click counting hits /json/url/{uuid}", () async {
      Uri? seen;
      final client = RadioBrowserClient(
        client: MockClient((request) async {
          seen = request.url;
          return http.Response('{"ok":true,"url":"http://stream.example/a"}', 200);
        }),
        userAgent: "Diapason/1",
        servers: ["de1.api.radio-browser.info"],
      );
      expect(await client.countClick("abc-123"), Uri.parse("http://stream.example/a"));
      expect(seen?.path, "/json/url/abc-123");
    });
  });

  group("Playlists", () {
    test("parses PLS in File order", () {
      const pls = '''
[playlist]
NumberOfEntries=3
File2=http://backup.example.com:8000/stream
Title1=Main
File1=http://main.example.com/stream
file3 = not a url
Length1=-1
Version=2
''';
      expect(RadioPlaylist.parsePls(pls), [
        Uri.parse("http://main.example.com/stream"),
        Uri.parse("http://backup.example.com:8000/stream"),
      ]);
    });

    test("parses M3U, skipping comments and resolving relative entries", () {
      const m3u = '''
#EXTM3U
#EXTINF:-1,My Radio
http://radio.example.com/live.mp3

relative/stream.aac
''';
      expect(RadioPlaylist.parseM3u(m3u, base: Uri.parse("https://host.example/lists/radio.m3u")), [
        Uri.parse("http://radio.example.com/live.mp3"),
        Uri.parse("https://host.example/lists/relative/stream.aac"),
      ]);
      expect(RadioPlaylist.parseM3u("relative/only.mp3"), isEmpty);
    });

    test("tells HLS playlists apart from plain lists", () {
      expect(RadioPlaylist.isHlsPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nchunk.m3u8"), isTrue);
      expect(RadioPlaylist.isHlsPlaylist("#EXTM3U\nhttp://a/b.mp3"), isFalse);
    });

    test("parse picks PLS by content or extension", () {
      expect(RadioPlaylist.parse("[playlist]\nFile1=http://a.example/s"), [Uri.parse("http://a.example/s")]);
      expect(RadioPlaylist.parse("File1=http://a.example/s", base: Uri.parse("http://x.example/listen.pls")), [
        Uri.parse("http://a.example/s"),
      ]);
    });

    test("resolve follows a playlist to the stream and keeps direct streams", () async {
      final client = MockClient((request) async {
        switch (request.url.path) {
          case "/listen.pls":
            return http.Response(
              "[playlist]\nFile1=http://stream.example/live",
              200,
              headers: {"content-type": "audio/x-scpls"},
            );
          case "/hls.m3u8":
            return http.Response(
              "#EXTM3U\n#EXT-X-TARGETDURATION:6\nseg1.aac",
              200,
              headers: {"content-type": "application/vnd.apple.mpegurl"},
            );
          default:
            return http.Response("audio bytes", 200, headers: {"content-type": "audio/mpeg"});
        }
      });
      final pls = await RadioPlaylist.resolve(Uri.parse("http://host.example/listen.pls"), client: client);
      expect(pls.uri, Uri.parse("http://stream.example/live"));
      expect(pls.isHls, isFalse);

      final hls = await RadioPlaylist.resolve(Uri.parse("http://host.example/hls.m3u8"), client: client);
      expect(hls.uri, Uri.parse("http://host.example/hls.m3u8"));
      expect(hls.isHls, isTrue);

      final direct = await RadioPlaylist.resolve(Uri.parse("http://host.example/stream"), client: client);
      expect(direct.uri, Uri.parse("http://host.example/stream"));
    });
  });

  group("ICY metadata", () {
    test("splits 'Artist - Title'", () {
      final np = IcyNowPlaying.parse("Daft Punk - Around the World");
      expect(np?.artist, "Daft Punk");
      expect(np?.title, "Around the World");
    });

    test("keeps hyphenated names and splits on the first spaced dash", () {
      final np = IcyNowPlaying.parse("Jean-Michel Jarre - Oxygène - Part 4");
      expect(np?.artist, "Jean-Michel Jarre");
      expect(np?.title, "Oxygène - Part 4");
    });

    test("en dash separator and whitespace cleanup", () {
      final np = IcyNowPlaying.parse("  Nina   Simone – Feeling Good ");
      expect(np?.artist, "Nina Simone");
      expect(np?.title, "Feeling Good");
    });

    test("no separator gives a title only; placeholders give null", () {
      expect(IcyNowPlaying.parse("Morning Show")?.artist, isNull);
      expect(IcyNowPlaying.parse("Morning Show")?.title, "Morning Show");
      expect(IcyNowPlaying.parse(" - Title only")?.title, "Title only");
      expect(IcyNowPlaying.parse(""), isNull);
      expect(IcyNowPlaying.parse("-"), isNull);
      expect(IcyNowPlaying.parse(null), isNull);
    });

    test("extracts StreamTitle from a metadata block", () {
      expect(
        IcyNowPlaying.streamTitleFromBlock("StreamTitle='Air - La femme d'argent';StreamUrl='';"),
        "Air - La femme d'argent",
      );
      expect(IcyNowPlaying.streamTitleFromBlock("StreamUrl='x';"), isNull);
    });

    test("block reader skips audio and decodes the metadata block across chunks", () {
      const metaInt = 8;
      const text = "StreamTitle='A - B';";
      final padded = utf8.encode(text);
      final blocks = (padded.length / 16).ceil();
      final meta = [...padded, ...List.filled(blocks * 16 - padded.length, 0)];
      final stream = [...List.filled(metaInt, 7), blocks, ...meta];

      final reader = IcyBlockReader(metaInt);
      String? result;
      for (var i = 0; i < stream.length && result == null; i += 5) {
        result = reader.add(stream.sublist(i, (i + 5).clamp(0, stream.length)));
      }
      expect(result, text);
    });

    test("block reader waits past empty blocks", () {
      final reader = IcyBlockReader(4);
      final title = utf8.encode("StreamTitle='X';");
      final meta = [...title, ...List.filled(16 - title.length, 0)];
      final stream = [1, 2, 3, 4, 0, 5, 6, 7, 8, 1, ...meta];
      expect(reader.add(stream), "StreamTitle='X';");
    });
  });

  group("RadioStation", () {
    test("JSON round trip and queue item round trip", () {
      final station = RadioStation.listFromRadioBrowserJson(jsonDecode(_stationJson)).first;
      final copy = RadioStation.fromJson(jsonDecode(jsonEncode(station.toJson())) as Map<String, dynamic>);
      expect(copy.toJson(), station.toJson());

      final item = station.toBaseItem(isFavorite: true);
      expect(RadioStation.isLiveItem(item), isTrue);
      expect(RadioStation.isStationItem(item), isTrue);
      expect(item.id.sourceId, RadioStation.sourceId);
      expect(item.userData?.isFavorite, isTrue);
      expect(RadioStation.directoryUuidOf(item), station.id);
      expect(RadioStation.faviconOf(item), Uri.parse(station.faviconUrl!));

      final back = RadioStation.fromBaseItem(item)!;
      expect(back.id, station.id);
      expect(back.name, station.name);
      expect(back.streamUrl, station.streamUrl);
      expect(back.isCustom, isFalse);
    });

    test("custom stations are not counted as directory clicks", () {
      final custom = RadioStation(id: "custom-1", name: "Mine", streamUrl: "http://a.example/s", isCustom: true);
      expect(RadioStation.directoryUuidOf(custom.toBaseItem()), isNull);
      expect(RadioStation.fromBaseItem(custom.toBaseItem())?.isCustom, isTrue);
    });
  });
}
