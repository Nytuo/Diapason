import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/plugins/plugin_host.dart';
import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:diapason/services/plugins/plugin_runtime.dart';
import 'package:diapason/services/plugins/wasm_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final wasm = File("plugins/examples/musicbrainz-wasm/plugin.wasm").readAsBytesSync();

  late MemoryPluginStorage storage;
  late PluginLog log;
  late List<Uri> requested;

  PluginHostBridge bridge(List<PluginPermission> granted) {
    storage = MemoryPluginStorage();
    log = PluginLog("org.diapason.example.musicbrainz");
    requested = [];
    return PluginHostBridge(
      pluginId: "org.diapason.example.musicbrainz",
      granted: granted,
      log: log,
      storage: storage,
      services: PluginHostServices(isOffline: () => false),
      httpClient: MockClient((request) async {
        requested.add(request.url);
        return http.Response(jsonEncode({"count": 42, "release-groups": <Object?>[]}), 200);
      }),
    );
  }

  Map<String, Object?> run(String command, String type, String name) => {
    "command": command,
    "item": {"type": type, "id": "1", "name": name, "title": name, "artist": "", "album": ""},
  };

  test("the example module passes validation", () async {
    await WasmRuntime.validate(wasm);
  });

  test("a command runs, uses its storage and logs through the host", () async {
    final runtime = WasmRuntime(
      module: wasm,
      bridge: bridge([
        NetworkPermission(["musicbrainz.org"]),
        const StoragePermission(),
      ]),
    );
    addTearDown(runtime.dispose);
    final first = await runtime.call(PluginMethods.commandRun, run("open", "album", "OK Computer"));
    expect(first, {"openUrl": "https://musicbrainz.org/search?type=release_group&query=OK%20Computer"});
    await runtime.call(PluginMethods.commandRun, run("open", "artist", "Björk"));
    expect(storage.values["runs"], "2");
    expect(log.entries.map((e) => e.message), contains(contains("Björk (use #2)")));
  });

  test("fetch goes through the host and reaches only granted hosts", () async {
    final runtime = WasmRuntime(
      module: wasm,
      bridge: bridge([
        NetworkPermission(["musicbrainz.org"]),
        const StoragePermission(),
      ]),
    );
    addTearDown(runtime.dispose);
    final result = await runtime.call(PluginMethods.commandRun, run("count", "artist", "Radiohead"));
    expect(result, {"message": "MusicBrainz has 42 matches for Radiohead"});
    expect(requested.single.host, "musicbrainz.org");
    expect(requested.single.queryParameters["query"], "Radiohead");
  });

  test("without the grants, storage and network are refused", () async {
    final runtime = WasmRuntime(module: wasm, bridge: bridge(const []));
    addTearDown(runtime.dispose);
    await expectLater(
      runtime.call(PluginMethods.commandRun, run("count", "artist", "Radiohead")),
      throwsA(isA<PluginCallException>().having((e) => e.message, "message", contains("not among"))),
    );
    expect(requested, isEmpty);
    // "open" still works: storage.set is refused and the counter just stays at one.
    await runtime.call(PluginMethods.commandRun, run("open", "track", "Airbag"));
    expect(storage.values, isEmpty);
    expect(log.entries.where((e) => e.level == PluginLogLevel.warning), isNotEmpty);
  });

  test("a plugin error is reported, not treated as a crash", () async {
    final runtime = WasmRuntime(module: wasm, bridge: bridge(const []));
    addTearDown(runtime.dispose);
    await expectLater(
      runtime.call(PluginMethods.commandRun, run("nope", "track", "x")),
      throwsA(isA<PluginCallException>().having((e) => e.message, "message", "unknown command")),
    );
    expect(runtime.suspendedReason, isNull);
  });

  test("invalid modules are rejected", () async {
    await expectLater(WasmRuntime.validate(Uint8List.fromList([0, 1, 2, 3])), throwsA(isA<PluginCallException>()));
  });

  test("an endless loop times out, the plugin is restarted, then suspended", () async {
    // (memory (export "memory") 1)
    // (func (export "diapason_alloc") (param i32) (result i32) i32.const 16)
    // (func (export "diapason_handle") (param i32 i32) (result i32) (loop br 0) unreachable)
    List<int> name(String s) => [s.length, ...s.codeUnits];
    final exports = [3, ...name("memory"), 2, 0, ...name("diapason_alloc"), 0, 0, ...name("diapason_handle"), 0, 1];
    final looping = Uint8List.fromList([
      0,
      0x61,
      0x73,
      0x6d,
      1,
      0,
      0,
      0,
      1,
      12,
      2,
      0x60,
      1,
      0x7f,
      1,
      0x7f,
      0x60,
      2,
      0x7f,
      0x7f,
      1,
      0x7f,
      3,
      3,
      2,
      0,
      1,
      5,
      3,
      1,
      0,
      1,
      7,
      exports.length,
      ...exports,
      10,
      15,
      2,
      4,
      0,
      0x41,
      16,
      0x0b,
      8,
      0,
      0x03,
      0x40,
      0x0c,
      0,
      0x0b,
      0,
      0x0b,
    ]);
    await WasmRuntime.validate(looping);
    final runtime = WasmRuntime(
      module: looping,
      bridge: bridge(const []),
      callTimeout: const Duration(seconds: 2),
      maxConsecutiveFailures: 2,
    );
    addTearDown(runtime.dispose);
    await expectLater(runtime.call(PluginMethods.lyrics, const {}), throwsA(isA<PluginCallException>()));
    expect(runtime.suspendedReason, isNull);
    await expectLater(runtime.call(PluginMethods.lyrics, const {}), throwsA(isA<PluginCallException>()));
    expect(runtime.suspendedReason, contains("2 failures"));
    await expectLater(
      runtime.call(PluginMethods.lyrics, const {}),
      throwsA(isA<PluginCallException>().having((e) => e.message, "message", contains("Suspended"))),
    );
    expect(log.entries.where((e) => e.message.startsWith("lyrics.get timed out")), hasLength(2));
  });
}
