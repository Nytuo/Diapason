import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:diapason/services/automix/mpv_pcm_decoder.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a track's audio can be read from: a local file, or a URL (with the headers the server wants).
class AnalysisSource {
  const AnalysisSource.file(String path) : uri = path, headers = const {}, isFile = true;

  const AnalysisSource.url(this.uri, {this.headers = const {}}) : isFile = false;

  final String uri;
  final Map<String, String> headers;
  final bool isFile;

  @override
  String toString() => isFile ? "file $uri" : "url ${Uri.tryParse(uri)?.host}";
}

/// Turns a window of a track into mono PCM at [sampleRate], for beat analysis.
///
/// * Android: MediaExtractor/MediaCodec (files and URLs), see AudioDecodeChannel.kt.
/// * iOS/macOS: AVAudioFile, local files only, so URLs are fetched to a temporary file first.
/// * Windows/Linux: the libmpv media_kit ships (files and URLs), see [MpvPcmDecoder].
class AudioAnalysisDecoder {
  static final _log = Logger("AudioAnalysisDecoder");
  static const _channel = MethodChannel("fr.nytuo.diapason/audio_decode");

  static const sampleRate = 11025;

  /// The first bytes fetched to analyse the start of a remote track on Apple platforms: enough for a minute of
  /// 320 kbps MP3, or about 25 s of FLAC.
  static const _darwinHeadBytes = 3 * 1024 * 1024;
  static const _darwinMaxBytes = 80 * 1024 * 1024;

  final http.Client _http;

  AudioAnalysisDecoder({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static bool get supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<Float32List?> decode(AnalysisSource source, {required Duration start, required Duration length}) async {
    try {
      if (Platform.isWindows || Platform.isLinux) return await _decodeWithMpv(source, start, length);
      if (Platform.isIOS || Platform.isMacOS) return await _decodeOnDarwin(source, start, length);
      if (Platform.isAndroid) return await _decodeNative(source.uri, source.headers, start, length);
    } catch (e) {
      _log.fine("Could not decode $source for analysis: $e");
    }
    return null;
  }

  Future<Float32List?> _decodeNative(String uri, Map<String, String> headers, Duration start, Duration length) {
    return _channel.invokeMethod<Float32List>("decode", {
      "source": uri,
      "headers": headers,
      "startMs": start.inMilliseconds,
      "durationMs": length.inMilliseconds,
      "sampleRate": sampleRate,
    });
  }

  Future<Float32List?> _decodeWithMpv(AnalysisSource source, Duration start, Duration length) async {
    final scratch = p.join(
      (await getTemporaryDirectory()).path,
      "diapason-automix-${DateTime.now().microsecondsSinceEpoch}.wav",
    );
    final uri = source.uri;
    final headers = source.headers;
    return Isolate.run(
      () => MpvPcmDecoder.decode(
        source: uri,
        headers: headers,
        start: start,
        length: length,
        sampleRate: sampleRate,
        scratchPath: scratch,
      ),
    );
  }

  Future<Float32List?> _decodeOnDarwin(AnalysisSource source, Duration start, Duration length) async {
    if (source.isFile) return _decodeNative(source.uri, const {}, start, length);

    final temp = File(
      p.join((await getTemporaryDirectory()).path, "diapason-automix-${DateTime.now().microsecondsSinceEpoch}"),
    );
    try {
      // The start of a track: its first megabytes are usually enough (MP3, FLAC, faststart M4A).
      if (start == Duration.zero) {
        if (await _download(source, temp, maxBytes: _darwinHeadBytes)) {
          try {
            final head = await _decodeNative(temp.path, const {}, start, length);
            if (head != null && head.length > sampleRate * length.inSeconds * 0.8) return head;
          } catch (_) {}
        }
      }
      if (!await _download(source, temp, maxBytes: _darwinMaxBytes)) return null;
      return await _decodeNative(temp.path, const {}, start, length);
    } finally {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {}
    }
  }

  Future<bool> _download(AnalysisSource source, File to, {required int maxBytes}) async {
    final request = http.Request("GET", Uri.parse(source.uri))..headers.addAll(source.headers);
    if (maxBytes < _darwinMaxBytes) request.headers["Range"] = "bytes=0-${maxBytes - 1}";
    final response = await _http.send(request).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 && response.statusCode != 206) return false;

    final sink = to.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
        sink.add(chunk);
        received += chunk.length;
        if (received >= maxBytes) break;
      }
    } finally {
      await sink.close();
    }
    return received > 0;
  }
}
