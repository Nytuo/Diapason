import 'dart:convert';
import 'dart:io';

import 'package:diapason/services/plugins/plugin_catalog.dart';
import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:diapason/services/plugins/plugin_package.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plugin_test_helpers.dart';

void main() {
  List<String> errorsOf(Map<String, Object?> json) {
    try {
      PluginManifest.parse(json);
      return const [];
    } on ManifestException catch (e) {
      return e.errors;
    }
  }

  group("manifest", () {
    test("the example manifests are valid", () {
      for (final name in ["lyrics-ovh-deezer", "musicbrainz-wasm"]) {
        final manifest = PluginManifest.parseString(File("plugins/examples/$name/manifest.json").readAsStringSync());
        expect(manifest.extensions, isNotEmpty);
        // Round trip.
        expect(PluginManifest.parse(jsonDecode(jsonEncode(manifest.toJson()))).toJson(), manifest.toJson());
      }
    });

    test("reports every problem at once", () {
      final errors = errorsOf({
        "manifestVersion": 2,
        "id": "NotReverseDomain",
        "name": "",
        "version": "one",
        "author": "x",
        "minAppVersion": "0.1.0",
        "runtime": "python",
        "entry": "../escape.json",
        "permissions": [
          {"type": "filesystem"},
        ],
        "extensions": [
          {"point": "telepathy"},
        ],
      });
      expect(errors, hasLength(greaterThanOrEqualTo(7)));
      expect(errors, contains(contains("manifestVersion")));
      expect(errors, contains(contains("'id'")));
      expect(errors, contains(contains("unknown permission type 'filesystem'")));
      expect(errors, contains(contains("unknown extension point 'telepathy'")));
      expect(errors, contains(contains("'entry'")));
    });

    test("network hosts must be plain DNS names", () {
      for (final host in ["*", "*.com", "localhost", "https://a.com", "a.com:443", "1.2.3.*", "a..com"]) {
        expect(
          errorsOf(
            manifestJson(
              permissions: [
                {
                  "type": "network",
                  "hosts": [host],
                },
              ],
            ),
          ),
          isNotEmpty,
          reason: host,
        );
      }
      expect(errorsOf(manifestJson()), isEmpty);
    });

    test("wildcards cover subdomains only", () {
      final network = NetworkPermission(["*.dzcdn.net", "api.example.com"]);
      expect(network.allows("cdn-images.dzcdn.net"), isTrue);
      expect(network.allows("a.b.dzcdn.net"), isTrue);
      expect(network.allows("dzcdn.net"), isFalse);
      expect(network.allows("evildzcdn.net"), isFalse);
      expect(network.allows("API.EXAMPLE.COM"), isTrue);
      expect(network.allows("api.example.com.evil.org"), isFalse);
    });

    test("commands need an id, a title and targets", () {
      expect(
        errorsOf(
          manifestJson(
            runtime: "wasm",
            entry: "plugin.wasm",
            extensions: [
              {"point": "command"},
            ],
          ),
        ),
        containsAll([contains("unique lowercase 'id'"), contains("needs a 'title'"), contains("needs 'targets'")]),
      );
    });

    test("permissions beyond a grant", () {
      final manifest = PluginManifest.parse(
        manifestJson(
          permissions: [
            {
              "type": "network",
              "hosts": ["a.example.com", "b.example.com"],
            },
            {"type": "storage"},
          ],
        ),
      );
      final extra = manifest.permissionsBeyond([
        NetworkPermission(["a.example.com"]),
      ]);
      expect(extra.map((p) => p.toJson()), [
        {
          "type": "network",
          "hosts": ["b.example.com"],
        },
        {"type": "storage"},
      ]);
      expect(manifest.permissionsBeyond(manifest.permissions), isEmpty);
    });

    test("versions compare numerically", () {
      expect(compareVersions("0.11.0", "0.9.9"), greaterThan(0));
      expect(compareVersions("1.0.0-beta", "1.0.0"), lessThan(0));
      expect(compareVersions("1.2.3", "1.2.3"), 0);
    });
  });

  group("package", () {
    final handlers = jsonEncode({
      "lyrics": {
        "request": {"url": "https://api.example.com/{artist}/{title}"},
        "response": {"plain": r"$.lyrics"},
      },
    });

    test("reads a valid package and checks the checksum", () {
      final zip = zipOf({"manifest.json": jsonEncode(manifestJson()), "handlers.json": handlers});
      final package = PluginPackage.read(zip, appVersion: "0.11.0");
      expect(package.manifest.id, "org.example.test");
      expect(package.sha256, hasLength(64));
      expect(
        () => PluginPackage.read(zip, appVersion: "0.11.0", expectedSha256: "0" * 64),
        throwsA(isA<PluginPackageException>()),
      );
    });

    test("refuses unsafe paths, missing entries and newer app versions", () {
      expect(PluginPackage.normalizeEntryName("../x"), isNull);
      expect(PluginPackage.normalizeEntryName("/etc/passwd"), isNull);
      expect(PluginPackage.normalizeEntryName("a\\b"), isNull);
      expect(PluginPackage.normalizeEntryName("C:/x"), isNull);
      expect(PluginPackage.normalizeEntryName("./a/b.json"), "a/b.json");

      expect(
        () => PluginPackage.read(
          zipOf({"manifest.json": jsonEncode(manifestJson()), "handlers.json": handlers, "../evil": "x"}),
          appVersion: "0.11.0",
        ),
        throwsA(isA<PluginPackageException>()),
      );
      expect(
        () => PluginPackage.read(zipOf({"manifest.json": jsonEncode(manifestJson())}), appVersion: "0.11.0"),
        throwsA(isA<PluginPackageException>().having((e) => e.message, "message", contains("entry"))),
      );
      expect(
        () => PluginPackage.read(
          zipOf({"manifest.json": jsonEncode(manifestJson(minAppVersion: "9.0.0")), "handlers.json": handlers}),
          appVersion: "0.11.0",
        ),
        throwsA(isA<PluginPackageException>().having((e) => e.message, "message", contains("9.0.0"))),
      );
      expect(() => PluginPackage.read(zipOf({"handlers.json": handlers}), appVersion: "0.11.0"), throwsA(anything));
    });
  });

  group("catalog", () {
    test("resolves relative packages and flags unusable entries", () {
      final catalog = PluginCatalog.parse(
        "https://example.com/plugins/catalog.json",
        utf8.encode(
          jsonEncode({
            "version": 1,
            "name": "Example",
            "plugins": [
              {"id": "a.b", "name": "A", "version": "1.0.0", "package": "a.zip", "sha256": "a" * 64},
              {"id": "c.d", "name": "C", "version": "1.0.0", "package": "c.zip", "sha256": "nope"},
              {
                "id": "e.f",
                "name": "E",
                "version": "1.0.0",
                "package": "e.zip",
                "sha256": "b" * 64,
                "minAppVersion": "99.0.0",
              },
            ],
          }),
        ),
        appVersion: "0.11.0",
      );
      expect(catalog.name, "Example");
      expect(catalog.entries[0].packageUrl.toString(), "https://example.com/plugins/a.zip");
      expect(catalog.entries[0].installable, isTrue);
      expect(catalog.entries[1].problem, contains("SHA-256"));
      expect(catalog.entries[2].problem, contains("99.0.0"));
    });

    test("only http(s) catalog URLs without credentials", () {
      expect(PluginCatalog.normalizeUrl("file:///etc/catalog.json"), isNull);
      expect(PluginCatalog.normalizeUrl("https://user:pw@example.com/c.json"), isNull);
      expect(PluginCatalog.normalizeUrl(" https://example.com/c.json#x "), "https://example.com/c.json");
    });

    test("the example catalog matches the example packages", () {
      final catalog = PluginCatalog.parse(
        "https://example.com/plugins/catalog.json",
        File("plugins/catalog.json").readAsBytesSync(),
        appVersion: "0.11.0",
      );
      expect(
        catalog.entries.map((e) => e.id),
        containsAll(["org.diapason.example.lyrics-ovh-deezer", "org.diapason.example.musicbrainz"]),
      );
      expect(catalog.entries.every((e) => e.installable), isTrue);
    });
  });
}
