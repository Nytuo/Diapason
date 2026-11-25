import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Reads `window.diapasonConfig`, set by `diapason-config.js` (see
/// `docs/WEB_DOCKER.md`). The Docker image rewrites that file from its
/// environment at container start, so one image can be preset for any server.
/// Only string values are kept; a missing or malformed object yields `{}`.
Map<String, String> readWebRuntimeConfig() {
  final raw = globalContext["diapasonConfig"];
  if (raw == null || !raw.isA<JSObject>()) return const {};
  final config = raw as JSObject;
  final out = <String, String>{};
  for (final key in const ["SERVER_NAME", "SERVER_TYPE", "SERVER_URL", "SERVER_LOCK"]) {
    final value = config[key];
    if (value != null && value.isA<JSString>()) out[key] = (value as JSString).toDart;
  }
  return out;
}
