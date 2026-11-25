import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/web/web_server_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("WebServerPreset.parse", () {
    test("no preset when nothing is set", () {
      expect(WebServerPreset.parse(const {}), isNull);
      expect(WebServerPreset.parse(const {"SERVER_TYPE": "", "SERVER_URL": "", "SERVER_LOCK": "false"}), isNull);
    });

    test("maps server types case-insensitively", () {
      WebServerPreset? parse(String type) => WebServerPreset.parse({"SERVER_TYPE": type, "SERVER_URL": "http://x"});
      expect(parse("Jellyfin")?.kind, MediaSourceKind.jellyfin);
      expect(parse("navidrome")?.kind, MediaSourceKind.subsonic);
      expect(parse("SUBSONIC")?.kind, MediaSourceKind.subsonic);
      expect(parse("plex")?.kind, MediaSourceKind.plex);
    });

    test("ignores an unknown type or a missing URL", () {
      expect(WebServerPreset.parse(const {"SERVER_TYPE": "mpd", "SERVER_URL": "http://x"}), isNull);
      expect(WebServerPreset.parse(const {"SERVER_TYPE": "jellyfin"}), isNull);
    });

    test("reads name and lock", () {
      final preset = WebServerPreset.parse(const {
        "SERVER_TYPE": "jellyfin",
        "SERVER_URL": " http://jf:8096 ",
        "SERVER_NAME": "Home",
        "SERVER_LOCK": "TRUE",
      })!;
      expect(preset.url, "http://jf:8096");
      expect(preset.name, "Home");
      expect(preset.locked, isTrue);

      final unlocked = WebServerPreset.parse(const {
        "SERVER_TYPE": "plex",
        "SERVER_URL": "http://p",
        "SERVER_NAME": " ",
      })!;
      expect(unlocked.name, isNull);
      expect(unlocked.locked, isFalse);
    });
  });
}
