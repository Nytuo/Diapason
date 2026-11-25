import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/automix/audio_analysis_decoder.dart';
import 'package:diapason/services/automix/track_analysis_service.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The loudness outline of a track, [binCount] values in 0..1, for the waveform seek bar.
///
/// Peaks are computed from a local copy of the track only (a download, or a stream the cache holds in full): decoding
/// a remote stream would fetch the whole track a second time. Results are kept in memory and on disk (one byte per bin),
/// so a track is decoded once.
class WaveformService {
  WaveformService({AudioAnalysisDecoder? decoder}) : _decoder = decoder ?? AudioAnalysisDecoder();

  static WaveformService get instance {
    if (!GetIt.instance.isRegistered<WaveformService>()) {
      GetIt.instance.registerSingleton(WaveformService());
    }
    return GetIt.instance<WaveformService>();
  }

  static final _log = Logger("WaveformService");

  static const binCount = 600;
  static const _version = 1;
  static const _memoryEntries = 32;

  /// Samples kept for a whole track: about 4 M floats (16 MB) at most, 8 kHz at best.
  static const _maxSamples = 4000000;
  static const _maxRate = 8000;
  static const _minRate = 1500;

  final AudioAnalysisDecoder _decoder;
  final _memory = <String, Float32List>{};
  final _inFlight = <String, Future<Float32List?>>{};

  /// Keys that failed recently, so a bad file isn't decoded again on every rebuild.
  final _failed = <String>{};
  Directory? _directory;

  static bool get supported => AudioAnalysisDecoder.supported;

  /// A stable id for [item]: the backend item id, falling back to the media item id.
  static String? trackIdOf(MediaItem item) {
    final json = item.extras?["itemJson"];
    if (json is Map) {
      final id = json["Id"] ?? json["id"];
      if (id != null) return id.toString();
    }
    return item.id;
  }

  static String _key(String id, Duration duration) =>
      "$_version-${id.replaceAll(RegExp(r"[^A-Za-z0-9_.-]"), "_")}-${duration.inSeconds}";

  /// Peaks already known for [item], without decoding anything.
  Float32List? cached(MediaItem item) {
    final id = trackIdOf(item);
    final duration = item.duration;
    if (id == null || duration == null) return null;
    return _memory[_key(id, duration)];
  }

  /// The peaks of [item], or null while they can't be computed (no local file yet, unsupported platform, failure).
  ///
  /// With [retry], an earlier failure is forgotten first: a stream's cache file can fail to decode while it is still
  /// being written, and must not stay blacklisted for the rest of the session.
  Future<Float32List?> peaksFor(MediaItem item, {bool retry = false}) async {
    if (!supported) return null;
    final id = trackIdOf(item);
    final duration = item.duration;
    if (id == null || duration == null || duration <= Duration.zero) return null;
    final key = _key(id, duration);
    if (retry) _failed.remove(key);
    final known = _memory[key];
    if (known != null) return known;

    final fromDisk = await _readDisk(key);
    if (fromDisk != null) return _remember(key, fromDisk);
    if (_failed.contains(key)) return null;

    final path = await _localFileFor(item, id);
    if (path == null) return null;
    return _inFlight[key] ??= _compute(key, path, duration).whenComplete(() => _inFlight.remove(key));
  }

  /// A local file holding [item]: its download, or the player's cache file once the stream is cached in full.
  Future<String?> _localFileFor(MediaItem item, String id) async {
    final downloaded = item.extras?["downloadedTrackPath"];
    if (downloaded is String && downloaded.isNotEmpty && File(downloaded).existsSync()) return downloaded;

    if (!GetIt.instance.isRegistered<MusicPlayerBackgroundTask>()) return null;
    final current = GetIt.instance<MusicPlayerBackgroundTask>().sequenceState.currentSource;
    if (current is! IndexedAudioSource) return null;
    final tag = current.tag;
    if (tag is! FinampQueueItem || trackIdOf(tag.item) != id) return null;
    final source = await TrackAnalysisService.sourceFor(current);
    if (source == null || !source.isFile) return null;
    return source.uri.startsWith("file://") ? Uri.parse(source.uri).toFilePath() : source.uri;
  }

  Future<Float32List?> _compute(String key, String path, Duration duration) async {
    final watch = Stopwatch()..start();
    final rate = (_maxSamples / max(duration.inSeconds, 1)).floor().clamp(_minRate, _maxRate);
    try {
      final samples = await _decoder.decode(
        AnalysisSource.file(path),
        start: Duration.zero,
        length: duration + const Duration(seconds: 2),
        sampleRate: rate,
      );
      if (samples == null || samples.length < rate) {
        _log.fine("No samples to draw a waveform for $key");
        _failed.add(key);
        return null;
      }
      final peaks = await Isolate.run(() => computePeaks(samples, binCount));
      _log.fine("Waveform for $key in ${watch.elapsedMilliseconds}ms (${samples.length} samples at $rate Hz)");
      unawaited(_writeDisk(key, peaks));
      return _remember(key, peaks);
    } catch (e) {
      _log.fine("Could not compute the waveform of $key: $e");
      _failed.add(key);
      return null;
    }
  }

  /// Folds [samples] into [bins] values in 0..1: the RMS of each slice, mixed with its peak, normalised to the loudest
  /// slice (ignoring the top percent so one click doesn't flatten the rest).
  @visibleForTesting
  static Float32List computePeaks(Float32List samples, int bins) {
    final out = Float32List(bins);
    final n = samples.length;
    if (n == 0 || bins == 0) return out;
    for (var b = 0; b < bins; b++) {
      final start = (b * n / bins).floor();
      final end = max(start + 1, ((b + 1) * n / bins).floor()).clamp(0, n);
      var sumSq = 0.0;
      var peak = 0.0;
      for (var i = start; i < end; i++) {
        final v = samples[i].abs();
        sumSq += v * v;
        if (v > peak) peak = v;
      }
      final rms = sqrt(sumSq / max(end - start, 1));
      out[b] = rms * 0.7 + peak * 0.3;
    }
    final sorted = Float32List.fromList(out)..sort();
    final reference = sorted[(bins * 0.99).floor().clamp(0, bins - 1)];
    if (reference <= 1e-6) return Float32List(bins);
    for (var b = 0; b < bins; b++) {
      out[b] = (out[b] / reference).clamp(0.0, 1.0);
    }
    return out;
  }

  Float32List _remember(String key, Float32List peaks) {
    _memory.remove(key);
    _memory[key] = peaks;
    while (_memory.length > _memoryEntries) {
      _memory.remove(_memory.keys.first);
    }
    return peaks;
  }

  Future<Directory?> _dir() async {
    if (_directory != null) return _directory;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, "waveforms"));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return _directory = dir;
    } catch (_) {
      return null;
    }
  }

  Future<Float32List?> _readDisk(String key) async {
    final dir = await _dir();
    if (dir == null) return null;
    final file = File(p.join(dir.path, "$key.bin"));
    try {
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length != binCount) return null;
      final out = Float32List(binCount);
      for (var i = 0; i < binCount; i++) {
        out[i] = bytes[i] / 255.0;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String key, Float32List peaks) async {
    final dir = await _dir();
    if (dir == null) return;
    final bytes = Uint8List(peaks.length);
    for (var i = 0; i < peaks.length; i++) {
      bytes[i] = (peaks[i] * 255).round().clamp(0, 255);
    }
    try {
      await File(p.join(dir.path, "$key.bin")).writeAsBytes(bytes, flush: false);
    } catch (_) {}
  }
}
