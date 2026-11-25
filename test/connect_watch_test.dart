import 'dart:convert';

import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/connect/connect_mdns.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/connect/watch_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Records what is advertised and lets a test pretend services were found.
class _FakeMdns implements ConnectMdns {
  final registered = <Map<String, String>>[];
  int unregistered = 0;
  void Function(List<MdnsService>)? onChanged;

  @override
  Future<void> register({
    required String name,
    required String type,
    required int port,
    Map<String, String> txt = const {},
  }) async => registered.add(txt);

  @override
  Future<void> unregister() async => unregistered++;

  @override
  Future<void> startBrowse(String type, void Function(List<MdnsService> services) onChanged) async =>
      this.onChanged = onChanged;

  @override
  Future<void> stopBrowse() async => onChanged = null;
}

/// Protocol 2 (browse, art, playItem) and the watch's side of Connect.
void main() {
  late ConnectService service;
  late _FakeMdns mdns;

  setUp(() async {
    mdns = _FakeMdns();
    service = ConnectService(mdns: mdns);
    await service.start(deviceName: "Diapason Test");
  });

  tearDown(() => service.stop());

  Uri endpoint(String path) => Uri.parse("${service.serverUrl}/$path");
  ConnectDevice self() => ConnectDevice(name: "Self", baseUrl: service.serverUrl!);

  group("protocol version", () {
    test("devices that predate it read as protocol 1, which cannot be browsed", () {
      final old = ConnectStatus.fromJson({"state": "playing", "position": 1, "volume": 1});
      expect(old.protocol, 1);
      expect(old.canBrowse, isFalse);
    });

    test("round-trips through json", () {
      const status = ConnectStatus(state: "paused", position: 3, volume: 0.5, protocol: connectProtocolVersion);
      final back = ConnectStatus.fromJson(jsonDecode(jsonEncode(status.toJson())) as Map<String, dynamic>);
      expect(back.protocol, connectProtocolVersion);
      expect(back.canBrowse, isTrue);
    });
  });

  group("browse requests", () {
    test("go to a query string and come back unchanged", () {
      const request = ConnectBrowseRequest(ConnectBrowseView.children, parentId: "jf-1~a", start: 50, limit: 25);
      expect(ConnectBrowseRequest.tryParse(request.toQuery()), request);
      const search = ConnectBrowseRequest(ConnectBrowseView.search, query: "daft");
      expect(ConnectBrowseRequest.tryParse(search.toQuery()), search);
    });

    test("an unknown view, or a view missing what it needs, is refused", () {
      expect(ConnectBrowseRequest.tryParse({"view": "songs"}), isNull);
      expect(ConnectBrowseRequest.tryParse({}), isNull);
      expect(ConnectBrowseRequest.tryParse({"view": "children"}), isNull);
      expect(ConnectBrowseRequest.tryParse({"view": "search", "q": "  "}), isNull);
    });

    test("paging is kept within bounds", () {
      final r = ConnectBrowseRequest.tryParse({"view": "albums", "start": "-4", "limit": "100000"})!;
      expect(r.start, 0);
      expect(r.limit, ConnectBrowseRequest.maxLimit);
      expect(ConnectBrowseRequest.tryParse({"view": "albums", "limit": "x"})!.limit, ConnectBrowseRequest.defaultLimit);
    });
  });

  group("browse items", () {
    test("malformed rows are dropped, the rest read with defaults", () {
      final items = ConnectBrowseItem.listFrom({
        "items": [
          {"id": "a", "type": "album", "title": "Discovery", "subtitle": "Daft Punk", "art": true},
          {"id": "", "title": "no id"},
          "junk",
          {"id": "t", "type": "track", "title": "One More Time", "duration": 320.5},
          {"id": "x"},
        ],
      });
      expect(items.map((i) => i.id), ["a", "t", "x"]);
      expect(items[0].isContainer, isTrue);
      expect(items[0].hasArt, isTrue);
      expect(items[1].isTrack, isTrue);
      expect(items[1].duration, 320.5);
      expect(items[2].type, ConnectBrowseItem.other);
      expect(ConnectBrowseItem.listFrom("nope"), isEmpty);
    });

    test("round-trip through json", () {
      const item = ConnectBrowseItem(id: "p", type: "playlist", title: "Mix", subtitle: "12", hasArt: true);
      final back = ConnectBrowseItem.tryParse(jsonDecode(jsonEncode(item.toJson())))!;
      expect((back.id, back.type, back.title, back.subtitle, back.hasArt), ("p", "playlist", "Mix", "12", true));
    });

    test("play modes default to play", () {
      expect(ConnectPlayMode.parse("queue"), ConnectPlayMode.queue);
      expect(ConnectPlayMode.parse(null), ConnectPlayMode.play);
      expect(ConnectPlayMode.parse("bogus"), ConnectPlayMode.play);
    });
  });

  group("browse endpoint", () {
    test("a device without a library to browse answers 404, like an older one", () async {
      expect((await http.get(endpoint("browse?view=albums"))).statusCode, 404);
      expect(await service.browse(const ConnectBrowseRequest(ConnectBrowseView.albums), device: self()), isNull);
    });

    test("a bad request is refused", () async {
      service.browseProvider = (_) async => const [];
      expect((await http.get(endpoint("browse?view=children"))).statusCode, 400);
    });

    test("a controller gets the listing it asked for", () async {
      ConnectBrowseRequest? asked;
      service.browseProvider = (request) async {
        asked = request;
        return const [ConnectBrowseItem(id: "a1", type: "album", title: "Homework")];
      };
      final items = await service.browse(
        const ConnectBrowseRequest(ConnectBrowseView.albums, start: 50, limit: 10),
        device: self(),
      );
      expect(items!.single.title, "Homework");
      expect(asked, const ConnectBrowseRequest(ConnectBrowseView.albums, start: 50, limit: 10));
    });

    test("artwork is served with its type, and missing art is a 404", () async {
      service.artProvider = (id, size) async => id == "a1" ? (bytes: [1, 2, 3], contentType: "image/png") : null;
      final url = service.artUrl("a1", size: 120, device: self())!;
      expect(url.queryParameters, {"id": "a1", "size": "120"});
      final response = await http.get(url);
      expect(response.statusCode, 200);
      expect(response.headers["content-type"], "image/png");
      expect(response.bodyBytes, [1, 2, 3]);
      expect((await http.get(service.artUrl("nope", device: self())!)).statusCode, 404);
    });

    test("playItem reaches the device with its arguments", () async {
      final received = <ConnectCommand>[];
      service.onCommand = received.add;
      expect(await service.connect(self()), isTrue);
      expect(await service.sendCommand("playItem", args: {"id": "a1", "mode": "shuffle", "startIndex": 0}), isTrue);
      expect(received.single.action, "playItem");
      expect(received.single.args, {"id": "a1", "mode": "shuffle", "startIndex": 0});
      service.disconnect();
    });

    test("a command to a device that is gone reports it did not get there", () async {
      await service.connect(self());
      final url = service.serverUrl!;
      await service.stop();
      expect(await service.sendCommand("play"), isFalse);
      expect(url, isNotEmpty);
    });
  });

  group("queue jumps", () {
    final items = [
      for (final n in ["a", "b", "c", "d"]) {"Id": n, "Name": "Song $n", "AlbumArtist": "Artist $n"},
    ];

    test("in a linear queue the offset is the distance", () {
      final q = ConnectQueue(items: items, index: 1, position: 0);
      expect(q.playOrder, [0, 1, 2, 3]);
      expect(q.offsetTo(3), 2);
      expect(q.offsetTo(0), -1);
      expect(q.offsetTo(1), 0);
      expect(q.offsetTo(9), isNull);
      expect(q.offsetTo(3, from: 2), 1);
    });

    test("in a shuffled queue it follows the play order", () {
      final q = ConnectQueue(items: items, index: 2, position: 0, shuffleOrder: const [3, 2, 0, 1]);
      expect(q.offsetTo(1), 2);
      expect(q.offsetTo(3), -1);
    });

    test("tracks are described from their item json", () {
      final q = ConnectQueue(
        items: [
          ...items,
          {
            "Id": "e",
            "Name": "Feat",
            "Artists": ["Someone"],
          },
          {"Id": "f"},
        ],
        index: 0,
        position: 0,
      );
      expect(q.describe(0), (title: "Song a", artist: "Artist a"));
      expect(q.describe(4), (title: "Feat", artist: "Someone"));
      expect(q.describe(5), (title: "", artist: ""));
    });
  });

  group("a watch on the network", () {
    test("it is not advertised until it asks to be, and says it is a watch", () async {
      final watchMdns = _FakeMdns();
      final watch = ConnectService(mdns: watchMdns);
      await watch.start(deviceName: "Watch", role: ConnectDevice.roleWatch, advertise: false);
      expect(watchMdns.registered, isEmpty);
      await watch.setAdvertised(true);
      expect(watchMdns.registered.single["role"], "watch");
      await watch.setAdvertised(false);
      expect(watchMdns.unregistered, 1);
      await watch.stop();
    });

    test("a player does not announce a role, so older devices read it as before", () {
      expect(mdns.registered.single.containsKey("role"), isFalse);
      expect(mdns.registered.single["token"], isNotEmpty);
    });

    test("discovered devices carry their role", () async {
      await service.startDiscovery();
      mdns.onChanged!([
        const MdnsService(name: "Watch", host: "10.0.0.2.", port: 1, txt: {"token": "w", "role": "watch"}),
        const MdnsService(name: "TV", host: "10.0.0.3", port: 2, txt: {"token": "t"}),
        const MdnsService(name: "Broken", host: "10.0.0.4", port: 3),
      ]);
      final devices = service.devices.value;
      expect(devices.map((d) => (d.name, d.isWatch)), [("Watch", true), ("TV", false)]);
      expect(devices.first.baseUrl, "http://10.0.0.2:1/w/connect");
      await service.stopDiscovery();
    });

    test("a watch controlling a device does not register itself there as a speaker", () async {
      final watch = ConnectService(mdns: _FakeMdns());
      await watch.start(deviceName: "Watch", role: ConnectDevice.roleWatch, advertise: false);
      expect(await watch.connect(self()), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(service.devices.value, isEmpty);
      watch.disconnect();
      await watch.stop();
    });
  });

  group("accounts sent to a watch", () {
    Map<String, dynamic> account(String name, {String user = "alex", String kind = "subsonic"}) => {
      "sourceId": "x-1",
      "kind": kind,
      "name": name,
      "publicAddress": "http://navidrome.lan:4533",
      "username": user,
      "password": "pw",
    };

    String newId(MediaSourceKind kind, Iterable<String> taken) => MediaSourceConfig.newSourceId(kind, taken);

    test("new accounts get ids of their own; known ones, duplicates and malformed ones are skipped", () {
      final existing = [
        MediaSourceConfig(
          sourceId: "sub-1",
          kind: MediaSourceKind.subsonic,
          name: "Home",
          publicAddress: "http://navidrome.lan:4533",
          username: "alex",
        ),
      ];
      final offer = SourceOffer(
        profileName: "Home",
        from: "Phone",
        sources: [
          account("Home"),
          account("Sam", user: "sam"),
          account("Sam again", user: "sam"),
          account("Local", kind: "local"),
          {"kind": "subsonic"},
        ],
      );
      final added = newSourcesFromOffer(offer, existing: existing, newId: newId);
      expect(added.map((s) => s.username), ["sam"]);
      expect(added.single.sourceId, isNot("x-1"));
      expect(added.single.sourceId, isNot("sub-1"));
      expect(added.single.password, "pw");
    });
  });
}
