import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// What a radio station says is on air, from its ICY `StreamTitle`.
class IcyNowPlaying {
  const IcyNowPlaying({required this.title, this.artist, required this.raw});

  final String title;
  final String? artist;

  /// The StreamTitle as sent by the station.
  final String raw;

  /// Splits a StreamTitle into artist and title. Most stations send
  /// "Artist - Title"; anything else becomes the title alone. Returns null for
  /// empty or placeholder titles.
  static IcyNowPlaying? parse(String? streamTitle) {
    final raw = (streamTitle ?? "").replaceAll(RegExp(r"\s+"), " ").trim();
    if (raw.isEmpty || raw == "-" || raw == " - ") return null;
    // "- Title" or "Artist -": one side of the separator is missing.
    final stripped = raw.replaceFirst(RegExp(r"^[-–—]\s+"), "").replaceFirst(RegExp(r"\s+[-–—]$"), "").trim();
    if (stripped != raw) return stripped.isEmpty ? null : IcyNowPlaying(title: stripped, raw: raw);

    // Prefer the first " - " (with spaces) so hyphenated names stay intact;
    // fall back to an en/em dash separator.
    for (final separator in const [" - ", " – ", " — "]) {
      final i = raw.indexOf(separator);
      if (i > 0) {
        final artist = raw.substring(0, i).trim();
        final title = raw.substring(i + separator.length).trim();
        if (artist.isNotEmpty && title.isNotEmpty) return IcyNowPlaying(title: title, artist: artist, raw: raw);
        if (title.isNotEmpty) return IcyNowPlaying(title: title, raw: raw);
        if (artist.isNotEmpty) return IcyNowPlaying(title: artist, raw: raw);
      }
    }
    return IcyNowPlaying(title: raw, raw: raw);
  }

  /// Extracts `StreamTitle` from an ICY metadata block such as
  /// `StreamTitle='Artist - Title';StreamUrl='';`.
  static String? streamTitleFromBlock(String block) {
    final match =
        RegExp(r"StreamTitle='(.*?)';", dotAll: true).firstMatch(block) ??
        RegExp(r"StreamTitle='(.*)'", dotAll: true).firstMatch(block);
    return match?.group(1);
  }

  @override
  bool operator ==(Object other) => other is IcyNowPlaying && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => "IcyNowPlaying($raw)";
}

/// Reads ICY metadata in Dart, for player backends that do not report it
/// (the media_kit backend used on Linux and Windows always reports none).
///
/// Every [interval] it opens the stream with `Icy-MetaData: 1`, reads up to
/// the first metadata block (one `icy-metaint` worth of audio, usually 8–32
/// KiB) and disconnects.
class IcyPoller {
  IcyPoller(this.url, {this.interval = const Duration(seconds: 20), this.userAgent});

  static final _log = Logger("IcyPoller");

  final Uri url;
  final Duration interval;
  final String? userAgent;

  final _controller = StreamController<IcyNowPlaying?>.broadcast();
  Timer? _timer;
  bool _closed = false;
  bool _unsupported = false;
  http.Client? _client;

  Stream<IcyNowPlaying?> get stream => _controller.stream;

  void start() {
    unawaited(_poll());
    _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _client?.close();
    await _controller.close();
  }

  Future<void> _poll() async {
    if (_closed || _unsupported || _client != null) return;
    final client = _client = http.Client();
    try {
      final title = await readStreamTitle(
        url,
        client: client,
        userAgent: userAgent,
      ).timeout(const Duration(seconds: 20), onTimeout: () => "");
      if (title == null) {
        // No icy-metaint: the station sends no metadata, stop asking.
        _unsupported = true;
        _timer?.cancel();
        return;
      }
      // "" means only empty blocks were seen in time: keep the last title.
      if (!_closed && title.isNotEmpty) _controller.add(IcyNowPlaying.parse(title));
    } catch (e) {
      _log.fine("ICY poll of $url failed: $e");
    } finally {
      client.close();
      _client = null;
    }
  }

  /// Returns the stream's current StreamTitle ("" when the block is empty),
  /// or null when the server sends no ICY metadata.
  static Future<String?> readStreamTitle(Uri url, {http.Client? client, String? userAgent}) async {
    final c = client ?? http.Client();
    try {
      final request = http.Request("GET", url)..headers["Icy-MetaData"] = "1";
      if (userAgent != null) request.headers["User-Agent"] = userAgent;
      final response = await c.send(request).timeout(const Duration(seconds: 10));
      final metaInt = int.tryParse(response.headers["icy-metaint"] ?? "");
      if (metaInt == null || metaInt <= 0) {
        unawaited(response.stream.listen(null).cancel());
        return null;
      }
      final reader = IcyBlockReader(metaInt);
      await for (final chunk in response.stream.timeout(const Duration(seconds: 15))) {
        final block = reader.add(chunk);
        if (block != null) return streamTitleOrEmpty(block);
      }
      return "";
    } finally {
      if (client == null) c.close();
    }
  }

  static String streamTitleOrEmpty(String block) => IcyNowPlaying.streamTitleFromBlock(block) ?? "";
}

/// Incremental parser of an ICY stream: skips `metaInt` audio bytes, then
/// reads the length byte (×16) and the metadata block that follows.
class IcyBlockReader {
  IcyBlockReader(this.metaInt);

  final int metaInt;
  int _audioLeft = -1;
  int? _metaLength;
  final _meta = BytesBuilder();

  /// Feeds bytes; returns the first complete metadata block's text, if any.
  String? add(List<int> chunk) {
    if (_audioLeft < 0) _audioLeft = metaInt;
    var i = 0;
    while (i < chunk.length) {
      if (_audioLeft > 0) {
        final skip = (chunk.length - i).clamp(0, _audioLeft);
        _audioLeft -= skip;
        i += skip;
        continue;
      }
      if (_metaLength == null) {
        _metaLength = chunk[i] * 16;
        i++;
        if (_metaLength == 0) {
          // Empty block: the title did not change; wait for the next one.
          _metaLength = null;
          _audioLeft = metaInt;
        }
        continue;
      }
      final need = _metaLength! - _meta.length;
      final take = (chunk.length - i).clamp(0, need);
      _meta.add(chunk.sublist(i, i + take));
      i += take;
      if (_meta.length >= _metaLength!) {
        final bytes = _meta.takeBytes();
        final end = bytes.indexOf(0);
        final text = end < 0 ? bytes : bytes.sublist(0, end);
        // Stations use UTF-8 or Latin-1; try UTF-8 first.
        try {
          return utf8.decode(text);
        } on FormatException {
          return latin1.decode(text);
        }
      }
    }
    return null;
  }
}
