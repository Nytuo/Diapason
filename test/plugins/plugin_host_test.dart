import 'dart:convert';
import 'dart:io';

import 'package:diapason/services/plugins/extension_points.dart';
import 'package:diapason/services/plugins/plugin_host.dart';
import 'package:diapason/services/plugins/plugin_manager.dart';
import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:diapason/services/plugins/plugin_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'plugin_test_helpers.dart';

void main() {
  late List<http.BaseRequest> requests;
  late Map<String, http.Response Function(http.Request)> routes;
  var offline = false;

  http.Client client() => MockClient((request) async {
    requests.add(request);
    final handler = routes["${request.url.host}${request.url.path}"];
    return handler == null ? http.Response("not found", 404) : handler(request);
  });

  setUp(() {
    requests = [];
    routes = {};
    offline = false;
  });

  PluginHostBridge bridge(List<PluginPermission> granted, {PluginHostServices? services}) => PluginHostBridge(
    pluginId: "org.example.test",
    granted: granted,
    log: PluginLog("org.example.test"),
    storage: MemoryPluginStorage(),
    services: services ?? PluginHostServices(isOffline: () => offline),
    httpClient: client(),
  );

  group("host bridge permissions", () {
    test("fetch reaches granted https hosts only", () async {
      routes["api.example.com/ok"] = (_) => http.Response("{}", 200);
      final b = bridge([
        NetworkPermission(["api.example.com"]),
      ]);
      expect((await b.handle({"op": "http.fetch", "url": "https://api.example.com/ok"}))["status"], 200);
      for (final url in [
        "https://other.example.com/ok",
        "http://api.example.com/ok",
        "https://api.example.com.evil.org/ok",
        "file:///etc/passwd",
      ]) {
        final answer = await b.handle({"op": "http.fetch", "url": url});
        expect(answer["denied"], isTrue, reason: url);
      }
      expect(requests, hasLength(1));
    });

    test("redirects to other hosts are refused", () async {
      routes["api.example.com/hop"] = (_) =>
          http.Response("", 302, headers: {"location": "https://attacker.example.net/steal"});
      final answer = await bridge([
        NetworkPermission(["api.example.com"]),
      ]).handle({"op": "http.fetch", "url": "https://api.example.com/hop"});
      expect(answer["denied"], isTrue);
      expect(requests.map((r) => r.url.host), ["api.example.com"]);
    });

    test("cookies and host headers cannot be set; set-cookie is not returned", () async {
      routes["api.example.com/h"] = (_) => http.Response("{}", 200, headers: {"set-cookie": "a=b", "x-ok": "1"});
      final answer =
          await bridge([
            NetworkPermission(["api.example.com"]),
          ]).handle({
            "op": "http.fetch",
            "url": "https://api.example.com/h",
            "headers": {"Cookie": "session=1", "Host": "evil", "X-Custom": "yes"},
          });
      expect(requests.single.headers.keys.map((k) => k.toLowerCase()), isNot(contains("cookie")));
      expect(requests.single.headers["X-Custom"], "yes");
      expect((answer["headers"] as Map).containsKey("set-cookie"), isFalse);
    });

    test("offline mode blocks the network", () async {
      offline = true;
      final answer = await bridge([
        NetworkPermission(["api.example.com"]),
      ]).handle({"op": "http.fetch", "url": "https://api.example.com/ok"});
      expect(answer["denied"], isTrue);
      expect(requests, isEmpty);
    });

    test("storage, playback, now playing and library need their grants", () async {
      var played = false;
      final services = PluginHostServices(
        isOffline: () => false,
        playerControl: (_) async => played = true,
        nowPlaying: () async => {"title": "x"},
        librarySearch: (_, _) async => [
          {"id": "1"},
        ],
      );
      final none = bridge(const [], services: services);
      for (final request in [
        {"op": "storage.set", "key": "k", "value": "v"},
        {"op": "storage.get", "key": "k"},
        {"op": "player.control", "action": "pause"},
        {"op": "player.nowPlaying"},
        {"op": "library.search", "query": "x"},
      ]) {
        expect((await none.handle(request))["denied"], isTrue, reason: request["op"] as String);
      }
      expect(played, isFalse);

      final all = bridge(const [
        StoragePermission(),
        PlaybackControlPermission(),
        NowPlayingPermission(),
        LibraryReadPermission(),
      ], services: services);
      await all.handle({"op": "storage.set", "key": "k", "value": "v"});
      expect(await all.handle({"op": "storage.get", "key": "k"}), {"value": "v"});
      await all.handle({"op": "player.control", "action": "pause"});
      expect(played, isTrue);
      expect((await all.handle({"op": "player.control", "action": "rm -rf"}))["denied"], isFalse);
      expect(await all.handle({"op": "player.nowPlaying"}), {
        "track": {"title": "x"},
      });
    });

    test("unknown operations are errors, never crashes", () async {
      expect((await bridge(const []).handle({"op": "fs.read", "path": "/"}))["error"], contains("unknown"));
    });

    test("storage is capped", () async {
      final storage = MemoryPluginStorage();
      await expectLater(storage.set("big", "x" * (PluginStorage.maxBytes + 1)), throwsA(anything));
    });
  });

  group("declarative runtime", () {
    PluginManifest manifest() =>
        PluginManifest.parseString(File("plugins/examples/lyrics-ovh-deezer/manifest.json").readAsStringSync());
    final handlers = File("plugins/examples/lyrics-ovh-deezer/handlers.json").readAsStringSync();

    test("fills the template and maps the answer", () async {
      routes["api.lyrics.ovh/v1/Bj%C3%B6rk/J%C3%B3ga"] = (_) =>
          http.Response(jsonEncode({"lyrics": "All these accidents"}), 200);
      routes["api.deezer.com/search/album"] = (_) => http.Response(
        jsonEncode({
          "data": [
            {"cover_xl": "https://cdn-images.dzcdn.net/a.jpg"},
            {"cover_xl": "https://cdn-images.dzcdn.net/b.jpg"},
          ],
        }),
        200,
      );
      final runtime = DeclarativeRuntime.load(manifest(), handlers, bridge(manifest().permissions));
      expect(await runtime.call(PluginMethods.lyrics, {"artist": "Björk", "title": "Jóga"}), {
        "plain": "All these accidents",
        "synced": null,
      });
      expect(requests.last.url.toString(), "https://api.lyrics.ovh/v1/Bj%C3%B6rk/J%C3%B3ga");
      expect(await runtime.call(PluginMethods.coverArt, {"artist": "Björk", "album": "Homogenic"}), {
        "urls": ["https://cdn-images.dzcdn.net/a.jpg", "https://cdn-images.dzcdn.net/b.jpg"],
      });
      expect(requests.last.url.queryParameters["q"], "Björk Homogenic");
    });

    test("an empty placeholder or a 404 means no result", () async {
      final runtime = DeclarativeRuntime.load(manifest(), handlers, bridge(manifest().permissions));
      expect(await runtime.call(PluginMethods.lyrics, {"artist": "", "title": "x"}), isNull);
      expect(requests, isEmpty);
      expect(await runtime.call(PluginMethods.lyrics, {"artist": "a", "title": "b"}), isNull);
    });

    test("handlers are validated against the manifest", () {
      expect(
        () => DeclarativeRuntime.validate(
          PluginManifest.parse(manifestJson()),
          jsonEncode({
            "lyrics": {
              "request": {"url": "http://api.example.com/{title}"},
              "response": {"plain": "lyrics", "evil": r"$.x"},
            },
          }),
        ),
        throwsA(isA<ManifestException>().having((e) => e.errors, "errors", contains(contains("https URL template")))),
      );
      expect(
        () => DeclarativeRuntime.validate(
          PluginManifest.parse(
            manifestJson(
              extensions: [
                {"point": "scrobbler"},
              ],
            ),
          ),
          "{}",
        ),
        throwsA(isA<ManifestException>()),
      );
    });

    test("JSON paths", () {
      final json = {
        "a": [
          {"b": 1},
          {"b": 2},
        ],
        "c": {"d": "x"},
      };
      expect(JsonPath.evaluate(json, r"$.a[*].b"), [1, 2]);
      expect(JsonPath.evaluate(json, r"$.a[1].b"), [2]);
      expect(JsonPath.evaluate(json, r"$.c.d"), ["x"]);
      expect(JsonPath.evaluate(json, r"$.missing"), isEmpty);
      expect(JsonPath.isValid("a.b"), isFalse);
    });
  });

  group("plugin manager", () {
    late Directory root;
    late PluginManager manager;

    setUp(() async {
      root = await Directory.systemTemp.createTemp("diapason-plugins");
      manager = PluginManager(
        appVersion: "0.11.0",
        root: root,
        services: PluginHostServices(isOffline: () => false),
        httpClient: client(),
      );
    });

    tearDown(() async {
      manager.dispose();
      await root.delete(recursive: true);
    });

    test("install, disable, enable and uninstall register and remove extensions", () async {
      final pending = await manager.prepare(zipExample("lyrics-ovh-deezer"));
      expect(pending.permissionsToApprove, hasLength(1));
      await expectLater(manager.install(pending, granted: const []), throwsA(isA<PluginInstallException>()));

      await manager.install(pending, granted: pending.permissionsToApprove);
      const id = "org.diapason.example.lyrics-ovh-deezer";
      expect(manager[id]!.status, PluginStatus.running);
      expect(manager.registry.lyricsProviders.single.displayName, "lyrics.ovh");
      expect(manager.registry.coverArtProviders, hasLength(1));

      await manager.setEnabled(id, false);
      expect(manager.registry.lyricsProviders, isEmpty);
      await manager.setEnabled(id, true);
      expect(manager.registry.lyricsProviders, hasLength(1));

      await manager.uninstall(id);
      expect(manager.installed, isEmpty);
      expect(manager.registry.lyricsProviders, isEmpty);
      expect(Directory("${root.path}/packages/$id").existsSync(), isFalse);
    });

    test("cover art URLs on hosts that were not granted are dropped", () async {
      routes["api.deezer.com/search/album"] = (_) => http.Response(
        jsonEncode({
          "data": [
            {"cover_xl": "https://tracker.example.org/pixel.gif"},
            {"cover_xl": "https://cdn-images.dzcdn.net/ok.jpg"},
          ],
        }),
        200,
      );
      final pending = await manager.prepare(zipExample("lyrics-ovh-deezer"));
      await manager.install(pending, granted: pending.permissionsToApprove);
      final urls = await manager.registry.coverArtProviders.single.coverArt(
        const CoverArtQuery(artist: "a", album: "b"),
      );
      expect(urls.map((u) => u.toString()), ["https://cdn-images.dzcdn.net/ok.jpg"]);
    });

    test("an update asking for more needs approval of the new permissions only", () async {
      Map<String, Object?> manifest(String version, List<String> hosts) => {
        ...manifestJson(
          permissions: [
            {"type": "network", "hosts": hosts},
          ],
        ),
        "version": version,
      };
      final handlers = jsonEncode({
        "lyrics": {
          "request": {"url": "https://api.example.com/{title}"},
          "response": {"plain": r"$.lyrics"},
        },
      });
      final v1 = await manager.prepare(
        zipOf({
          "manifest.json": jsonEncode(manifest("1.0.0", ["api.example.com"])),
          "handlers.json": handlers,
        }),
      );
      await manager.install(v1, granted: v1.permissionsToApprove);

      final v2 = await manager.prepare(
        zipOf({
          "manifest.json": jsonEncode(manifest("1.1.0", ["api.example.com", "more.example.com"])),
          "handlers.json": handlers,
        }),
      );
      expect(v2.isUpdate, isTrue);
      expect(v2.permissionsToApprove.map((p) => p.toJson()), [
        {
          "type": "network",
          "hosts": ["more.example.com"],
        },
      ]);
      await manager.install(v2, granted: [...v2.existing!.record.granted, ...v2.permissionsToApprove]);
      expect(manager["org.example.test"]!.manifest.version, "1.1.0");
      expect(manager["org.example.test"]!.unapproved, isEmpty);
    });

    test("a WASM package with a broken module is refused at install", () async {
      final zip = zipOf({
        "manifest.json": jsonEncode(
          manifestJson(
            runtime: "wasm",
            entry: "plugin.wasm",
            extensions: [
              {
                "point": "command",
                "id": "x",
                "title": "X",
                "targets": ["track"],
              },
            ],
          ),
        ),
        "plugin.wasm": [0, 97, 115, 109, 9, 9, 9, 9],
      });
      await expectLater(manager.prepare(zip), throwsA(isA<PluginInstallException>()));
    });

    test("the WASM example installs and its commands are offered for matching items", () async {
      final pending = await manager.prepare(zipExample("musicbrainz-wasm"));
      await manager.install(pending, granted: pending.permissionsToApprove);
      expect(manager.registry.commandsFor(CommandTarget.track).map((c) => c.title), ["Open in MusicBrainz"]);
      expect(manager.registry.commandsFor(CommandTarget.album), hasLength(2));
      final result = await manager.registry
          .commandsFor(CommandTarget.artist)
          .first
          .run(const CommandItem(target: CommandTarget.artist, id: "1", name: "Portishead"));
      expect(result.openUrl.toString(), "https://musicbrainz.org/search?type=artist&query=Portishead");
    });
  });
}
