import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Parsing of the playlist files radio stations often publish instead of a
/// direct stream URL (.pls, .m3u, .asx-less plain lists), and resolution of a
/// station URL to something the player can open.
class RadioPlaylist {
  static final _log = Logger("RadioPlaylist");

  /// Stream URLs listed in a PLS file, in `File1`, `File2`… order.
  static List<Uri> parsePls(String content) {
    final entries = <int, Uri>{};
    for (final raw in const LineSplitter().convert(content)) {
      final line = raw.trim();
      final match = RegExp(r"^file(\d+)\s*=\s*(.+)$", caseSensitive: false).firstMatch(line);
      if (match == null) continue;
      final uri = _httpUri(match.group(2)!);
      if (uri != null) entries[int.parse(match.group(1)!)] = uri;
    }
    final keys = entries.keys.toList()..sort();
    return [for (final k in keys) entries[k]!];
  }

  /// Stream URLs listed in an M3U/M3U8 file (comments and directives skipped).
  /// Relative entries are resolved against [base] when given.
  static List<Uri> parseM3u(String content, {Uri? base}) {
    final result = <Uri>[];
    for (final raw in const LineSplitter().convert(content)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith("#")) continue;
      final uri = _httpUri(line) ?? (base == null ? null : _httpUri(base.resolve(line).toString()));
      if (uri != null) result.add(uri);
    }
    return result;
  }

  /// Whether an M3U8 body is an HLS playlist (to be played as is) rather than a
  /// plain list of stream URLs.
  static bool isHlsPlaylist(String content) =>
      content.contains("#EXT-X-TARGETDURATION") ||
      content.contains("#EXT-X-STREAM-INF") ||
      content.contains("#EXT-X-MEDIA-SEQUENCE") ||
      content.contains("#EXT-X-VERSION");

  /// Picks the parser from the URL's extension, the content type, or the body.
  static List<Uri> parse(String content, {Uri? base, String? contentType}) {
    final path = base?.path.toLowerCase() ?? "";
    final type = contentType?.toLowerCase() ?? "";
    if (path.endsWith(".pls") || type.contains("scpls") || content.trimLeft().toLowerCase().startsWith("[playlist]")) {
      return parsePls(content);
    }
    return parseM3u(content, base: base);
  }

  static Uri? _httpUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !(uri.isScheme("http") || uri.isScheme("https")) || uri.host.isEmpty) return null;
    return uri;
  }

  static bool looksLikePlaylistUrl(Uri uri) {
    final path = uri.path.toLowerCase();
    return path.endsWith(".pls") || path.endsWith(".m3u") || path.endsWith(".m3u8");
  }

  static const _playlistTypes = [
    "audio/x-scpls",
    "audio/scpls",
    "audio/x-mpegurl",
    "audio/mpegurl",
    "application/x-mpegurl",
    "application/vnd.apple.mpegurl",
    "application/pls+xml",
  ];

  /// Resolves a station URL to a playable stream: follows .pls/.m3u
  /// playlists (up to [maxDepth] levels), keeps HLS playlists as they are.
  ///
  /// Returns `(uri, isHls)`. Network problems leave the URL unchanged, so a
  /// direct stream with an unusual server still gets a chance in the player.
  static Future<({Uri uri, bool isHls})> resolve(Uri url, {http.Client? client, int maxDepth = 3}) async {
    final ownClient = client == null;
    final c = client ?? http.Client();
    try {
      var current = url;
      for (var depth = 0; depth < maxDepth; depth++) {
        final byExtension = looksLikePlaylistUrl(current);
        final http.StreamedResponse response;
        try {
          final request = http.Request("GET", current)..headers["Icy-MetaData"] = "0";
          response = await c.send(request).timeout(const Duration(seconds: 10));
        } catch (e) {
          _log.fine("Could not probe $current ($e); playing it as is");
          return (uri: current, isHls: current.path.toLowerCase().endsWith(".m3u8"));
        }

        final type = (response.headers["content-type"] ?? "").toLowerCase();
        final isPlaylistType = _playlistTypes.any(type.contains);
        if (!byExtension && !isPlaylistType) {
          // A real audio stream: drop the connection right away.
          unawaited(response.stream.listen(null).cancel());
          return (uri: current, isHls: false);
        }

        // Playlists are small; never read more than 256 KiB of something that
        // turns out to be a stream with a misleading extension.
        final bytes = <int>[];
        final completer = Completer<void>();
        late StreamSubscription<List<int>> sub;
        sub = response.stream.listen(
          (chunk) {
            bytes.addAll(chunk);
            if (bytes.length > 256 * 1024) {
              unawaited(sub.cancel());
              if (!completer.isCompleted) completer.complete();
            }
          },
          onDone: () => completer.isCompleted ? null : completer.complete(),
          onError: (Object e) => completer.isCompleted ? null : completer.complete(),
          cancelOnError: true,
        );
        await completer.future.timeout(const Duration(seconds: 10), onTimeout: () => sub.cancel());

        if (bytes.length > 256 * 1024) return (uri: current, isHls: false);
        final body = utf8.decode(bytes, allowMalformed: true);
        if (isHlsPlaylist(body)) return (uri: current, isHls: true);

        final entries = parse(body, base: current, contentType: type);
        if (entries.isEmpty) {
          _log.warning("Playlist $current lists no stream URL; trying it as a stream");
          return (uri: current, isHls: false);
        }
        _log.fine("Playlist $current -> ${entries.first}");
        current = entries.first;
      }
      return (uri: current, isHls: current.path.toLowerCase().endsWith(".m3u8"));
    } finally {
      if (ownClient) c.close();
    }
  }
}
