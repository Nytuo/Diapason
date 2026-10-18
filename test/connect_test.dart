import 'dart:convert';

import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Drives a real ConnectService over loopback: the protocol is HTTP, so this
/// exercises the actual wire format the iOS/Android/desktop apps speak.
void main() {
  late ConnectService service;
  late Uri base;

  setUp(() async {
    service = ConnectService();
    await service.start(deviceName: "Diapason Test");
    // start() advertises over mDNS, which may fail in CI; serving must still work.
    base = Uri.parse(service.serverUrl!);
  });

  tearDown(() => service.stop());

  Uri endpoint(String path) => Uri.parse("${service.serverUrl}/$path");

  test("serves status in the shape the other clients decode", () async {
    service.localStatusProvider = () => const ConnectStatus(
      song: ConnectSong(id: "jf-1~t1", title: "Song", artist: "Artist", album: "Album", duration: 180),
      state: "playing",
      position: 42.5,
      volume: 0.8,
    );

    final response = await http.get(endpoint("status"));
    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(response.statusCode, 200);
    expect(body["state"], "playing");
    expect(body["position"], 42.5);
    expect(body["volume"], 0.8);
    expect(body["song"]["title"], "Song");
    expect(body["song"]["duration"], 180);
  });

  test("reports stopped when nothing is playing", () async {
    final response = await http.get(endpoint("status"));
    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(body["state"], "stopped");
    expect(body["song"], isNull);
  });

  test("delivers commands, with their arguments", () async {
    final received = <ConnectCommand>[];
    service.onCommand = received.add;

    await http.post(endpoint("command"), body: jsonEncode({"action": "pause"}));
    await http.post(endpoint("command"), body: jsonEncode({"action": "seek", "position": 30.0}));
    await http.post(endpoint("command"), body: jsonEncode({"action": "volume", "volume": 0.5}));

    expect(received.map((c) => c.action), ["pause", "seek", "volume"]);
    expect(received[1].position, 30.0);
    expect(received[2].volume, 0.5);
  });

  test("accepts a queue pushed by an older device (bare ids)", () async {
    ConnectQueue? queue;
    service.onPlayQueue = (q) => queue = q;

    await http.post(
      endpoint("play-queue"),
      body: jsonEncode({
        "songs": [
          {"id": "jf-1~a"},
          {"id": "jf-1~b"},
        ],
        "startIndex": 1,
      }),
    );

    expect(queue!.items, hasLength(2));
    expect(queue!.items.first["Id"], "jf-1~a");
    expect(queue!.index, 1);
    expect(queue!.playing, isTrue);
  });

  test("accepts a whole queue: tracks, position, shuffle order and Next Up", () async {
    ConnectQueue? queue;
    service.onPlayQueue = (q) => queue = q;

    const sent = ConnectQueue(
      items: [
        {"Id": "jf-1~a", "Name": "A"},
        {"Id": "jf-1~b", "Name": "B"},
        {"Id": "jf-1~c", "Name": "C"},
      ],
      index: 2,
      position: 61.5,
      shuffleOrder: [2, 0, 1],
      nextUpLength: 0,
      playing: false,
      repeat: "all",
    );
    await http.post(endpoint("play-queue"), body: jsonEncode(sent.toJson()));

    expect(queue!.items.map((i) => i["Name"]), ["A", "B", "C"]);
    expect(queue!.index, 2);
    expect(queue!.position, 61.5);
    expect(queue!.shuffleOrder, [2, 0, 1]);
    expect(queue!.playing, isFalse);
    expect(queue!.repeat, "all");
    expect(queue!.version, sent.version);
  });

  test("serves its queue for a controller to mirror", () async {
    service.queueProvider = () => const ConnectQueue(
      items: [
        {"Id": "jf-1~a"},
        {"Id": "jf-1~b"},
      ],
      index: 1,
      position: 12,
    );

    final response = await http.get(endpoint("queue"));
    final queue = ConnectQueue.tryParse(jsonDecode(response.body) as Map<String, dynamic>)!;

    expect(queue.items, hasLength(2));
    expect(queue.index, 1);
    expect(queue.position, 12);
  });

  test("queue versions change with the tracks and the shuffle, not with time", () {
    final a = ConnectQueue.versionOf(["x", "y"], null);
    expect(ConnectQueue.versionOf(["x", "y"], null), a);
    expect(ConnectQueue.versionOf(["y", "x"], null), isNot(a));
    expect(ConnectQueue.versionOf(["x", "y"], [1, 0]), isNot(a));
    expect(ConnectQueue.versionOf(["x", "y", "z"], null), isNot(a));
  });

  test("queue commands carry their arguments", () async {
    final received = <ConnectCommand>[];
    service.onCommand = received.add;

    await http.post(
      endpoint("command"),
      body: jsonEncode(const ConnectCommand("reorder", args: {"from": 2, "to": 5}).toJson()),
    );

    expect(received.single.action, "reorder");
    expect(received.single.args, {"from": 2, "to": 5});
  });

  test("controlling another device: status is polled and commands reach it", () async {
    final other = ConnectService();
    await other.start(deviceName: "Other");
    addTearDown(other.stop);
    final received = <ConnectCommand>[];
    other.onCommand = received.add;
    other.localStatusProvider = () =>
        const ConnectStatus(state: "playing", position: 3, volume: 0.4, queueVersion: "v1");

    final device = ConnectDevice(name: "Other", baseUrl: other.serverUrl!);
    expect(await service.connect(device), isTrue);
    expect(service.connectedDevice.value, device);
    expect(service.remoteStatus.value!.queueVersion, "v1");
    expect(service.remoteStatus.value!.volume, 0.4);

    await service.sendCommand("skipBy", args: {"offset": 2});
    expect(received.single.action, "skipBy");
    expect(received.single.args["offset"], 2);
  });

  test("a device that does not answer cannot be connected to", () async {
    final ok = await service.connect(const ConnectDevice(name: "Gone", baseUrl: "http://127.0.0.1:1/x/connect"));
    expect(ok, isFalse);
    expect(service.connectedDevice.value, isNull);
  });

  test("serves a library to companions that have none of their own", () async {
    // What the Apple Watch fetches. Each track carries a direct URL to the music
    // server, not one pointing back at this phone — that is what lets the watch
    // stream and download with the phone switched off.
    service.libraryProvider = () async => [
      {
        "id": "sub-1~t1",
        "title": "Song",
        "artist": "Artist",
        "album": "Album",
        "duration": 180,
        "streamUrl": "https://navidrome.example.com/rest/stream.view?id=t1&u=me&t=abc",
        "art": null,
      },
    ];

    final response = await http.get(endpoint("library"));
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final track = (body["tracks"] as List<dynamic>).single as Map<String, dynamic>;

    expect(response.statusCode, 200);
    expect(track["id"], "sub-1~t1");
    expect(track["duration"], 180);
    // The URL must go to the server, never to this phone.
    expect(track["streamUrl"], startsWith("https://navidrome.example.com"));
  });

  test("an empty library is served as an empty list, not an error", () async {
    final response = await http.get(endpoint("library"));
    final body = jsonDecode(response.body) as Map<String, dynamic>;

    expect(response.statusCode, 200);
    expect(body["tracks"], isEmpty);
  });

  test("a device can register itself with us", () async {
    await http.post(
      endpoint("register"),
      body: jsonEncode({"name": "Diapason Desktop", "url": "http://192.168.1.5:9999/abc/connect"}),
    );

    expect(service.devices.value.single.name, "Diapason Desktop");
    expect(service.devices.value.single.baseUrl, "http://192.168.1.5:9999/abc/connect");
  });

  test("the token is the access check: a wrong one gets nothing", () async {
    // Knowing the URL is the permission — a device that never saw the mDNS
    // advertisement cannot drive playback.
    var commanded = false;
    service.onCommand = (_) => commanded = true;

    final wrong = base.replace(path: "/not-the-token/connect/command");
    final response = await http.post(wrong, body: jsonEncode({"action": "pause"}));

    expect(response.statusCode, 404);
    expect(commanded, isFalse);
  });

  test("an unknown endpoint under a valid token is still refused", () async {
    final response = await http.get(endpoint("wat"));
    expect(response.statusCode, 404);
  });

  test("malformed json does not take the server down", () async {
    var commanded = false;
    service.onCommand = (_) => commanded = true;

    final response = await http.post(endpoint("command"), body: "{not json");

    expect(response.statusCode, 200);
    expect(commanded, isFalse, reason: "nothing usable arrived, so nothing was done");
    // Still serving afterwards.
    expect((await http.get(endpoint("status"))).statusCode, 200);
  });

  test("answers CORS preflight, so the desktop web UI can drive it", () async {
    final request = http.Request("OPTIONS", endpoint("command"));
    final response = await http.Client().send(request);

    expect(response.statusCode, 204);
    expect(response.headers["access-control-allow-origin"], "*");
  });

  group("status round-trips", () {
    test("through json, unchanged", () {
      const original = ConnectStatus(
        song: ConnectSong(id: "x", title: "T", artist: "A", album: "Al", duration: 1.5, art: "http://art"),
        state: "paused",
        position: 9.25,
        volume: 0.3,
      );

      final decoded = ConnectStatus.fromJson(jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(decoded.state, "paused");
      expect(decoded.position, 9.25);
      expect(decoded.volume, 0.3);
      expect(decoded.song!.art, "http://art");
      expect(decoded.song!.duration, 1.5);
    });
  });

  group("sending accounts", () {
    Map<String, dynamic> account(String name) => {
      "sourceId": "sub-1",
      "kind": "subsonic",
      "name": name,
      "publicAddress": "http://navidrome.lan:4533",
      "username": "alex",
      "password": "pw",
    };

    late ConnectDevice self;

    setUp(() => self = ConnectDevice(name: "TV", baseUrl: service.serverUrl!));

    test("a device that does not take accounts refuses them", () async {
      expect(await service.sendSources(self, [account("Home")]), isFalse);
      expect(service.sourceOffer.value, isNull);
    });

    test("a TV on its start screen gets the offer to ask its user about", () async {
      service.acceptSources = true;
      expect(await service.sendSources(self, [account("Home")], profileName: "Alex", from: "Phone"), isTrue);

      final offer = service.sourceOffer.value!;
      expect(offer.profileName, "Alex");
      expect(offer.from, "Phone");
      expect(offer.sources.single["publicAddress"], "http://navidrome.lan:4533");
    });

    test("an empty or oversized offer is rejected", () async {
      service.acceptSources = true;
      expect(await service.sendSources(self, const []), isFalse);
      expect(
        await service.sendSources(self, List.generate(SourceOffer.maxSources + 1, (i) => account("n$i"))),
        isFalse,
      );
      expect(service.sourceOffer.value, isNull);
    });
  });
}
