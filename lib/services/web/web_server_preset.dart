import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/web/web_runtime_config.dart'
    if (dart.library.js_interop) 'package:diapason/services/web/web_runtime_config_web.dart';
import 'package:logging/logging.dart';

/// The server a self-hosted web deployment is preset for (the `SERVER_*`
/// environment of the Docker image, see `docs/WEB_DOCKER.md`).
///
/// With a type and URL, the login flow skips the "where's your music?" step
/// and opens that server's form pre-filled. With [locked] as well, the address
/// can't be edited and no other kind of source can be added, so only the
/// credentials are left to the user.
class WebServerPreset {
  const WebServerPreset({required this.kind, required this.url, this.name, this.locked = false});

  static final _log = Logger("WebServerPreset");

  final MediaSourceKind kind;
  final String url;
  final String? name;
  final bool locked;

  /// The preset of this deployment, or null when none (always null outside a browser).
  static final WebServerPreset? current = parse(readWebRuntimeConfig());

  /// Builds a preset from the raw `SERVER_*` values; null unless both a known type and a URL are set.
  static WebServerPreset? parse(Map<String, String> raw) {
    final type = raw["SERVER_TYPE"]?.trim().toLowerCase() ?? "";
    final url = raw["SERVER_URL"]?.trim() ?? "";
    if (type.isEmpty && url.isEmpty) return null;
    final kind = switch (type) {
      "jellyfin" => MediaSourceKind.jellyfin,
      "subsonic" || "navidrome" || "opensubsonic" => MediaSourceKind.subsonic,
      "plex" => MediaSourceKind.plex,
      _ => null,
    };
    if (kind == null || url.isEmpty) {
      _log.warning("Ignoring the server preset: SERVER_TYPE '$type' and SERVER_URL '$url' must both be set and valid");
      return null;
    }
    final name = raw["SERVER_NAME"]?.trim() ?? "";
    final lock = raw["SERVER_LOCK"]?.trim().toLowerCase() ?? "";
    return WebServerPreset(
      kind: kind,
      url: url,
      name: name.isEmpty ? null : name,
      locked: lock == "true" || lock == "1" || lock == "yes",
    );
  }
}
