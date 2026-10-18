import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:diapason/services/automix/audio_analysis_decoder.dart';
import 'package:diapason/services/automix/beat_analyzer.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum AnalysisWindow { head, tail }

/// Analyses the start or the end of tracks for Automix, and remembers the results (in memory and on disk), so a
/// track is only ever decoded once per end.
class TrackAnalysisService {
  TrackAnalysisService({AudioAnalysisDecoder? decoder}) : _decoder = decoder ?? AudioAnalysisDecoder();

  static final _log = Logger("TrackAnalysis");

  static const headLength = Duration(seconds: 40);
  static const tailLength = Duration(seconds: 45);
  static const _memoryEntries = 64;
  static const _version = 1;

  final AudioAnalysisDecoder _decoder;
  final _memory = <String, BeatAnalysis>{};
  final _inFlight = <String, Future<BeatAnalysis?>>{};
  Directory? _directory;

  bool get supported => AudioAnalysisDecoder.supported;

  /// Where [source] (an item of the player's queue) can be read from for analysis. A stream that is fully cached
  /// is read from the cache file.
  static Future<AnalysisSource?> sourceFor(AudioSource? source) async {
    if (source is LockCachingAudioSource) {
      try {
        final file = await source.cacheFile;
        if (file.existsSync() && !File("${file.path}.part").existsSync()) return AnalysisSource.file(file.path);
      } catch (_) {}
      return AnalysisSource.url(source.uri.toString(), headers: source.headers ?? const {});
    }
    if (source is UriAudioSource) {
      final uri = source.uri;
      if (uri.scheme == "file") return AnalysisSource.file(uri.toFilePath());
      return AnalysisSource.url(uri.toString(), headers: source.headers ?? const {});
    }
    return null;
  }

  /// The analysis of one end of a track. [id] identifies the track (its item id), [duration] is its length.
  Future<BeatAnalysis?> analyze({
    required String id,
    required AnalysisSource source,
    required Duration duration,
    required AnalysisWindow window,
  }) {
    final key = "$_version-${window.name}-$id-${duration.inSeconds}";
    final cached = _memory[key];
    if (cached != null) return Future.value(cached);
    return _inFlight[key] ??= _analyze(key, source, duration, window).whenComplete(() => _inFlight.remove(key));
  }

  Future<BeatAnalysis?> _analyze(String key, AnalysisSource source, Duration duration, AnalysisWindow window) async {
    final fromDisk = await _readDisk(key);
    if (fromDisk != null) return _remember(key, fromDisk);

    final length = window == AnalysisWindow.head ? headLength : tailLength;
    var start = window == AnalysisWindow.head ? Duration.zero : duration - length;
    if (start.isNegative) start = Duration.zero;

    final watch = Stopwatch()..start();
    final samples = await _decoder.decode(source, start: start, length: length);
    if (samples == null || samples.length < AudioAnalysisDecoder.sampleRate * 6) {
      _log.fine("Nothing to analyse for the ${window.name} of $key ($source)");
      return null;
    }
    final decodedIn = watch.elapsedMilliseconds;
    final offset = start.inMilliseconds / 1000;
    final analysis = await Isolate.run(
      () => BeatAnalyzer.analyze(samples, sampleRate: AudioAnalysisDecoder.sampleRate, offset: offset),
    );
    _log.fine(
      "Analysed the ${window.name} of $key in ${decodedIn}ms + ${watch.elapsedMilliseconds - decodedIn}ms: $analysis",
    );
    unawaited(_writeDisk(key, analysis));
    return _remember(key, analysis);
  }

  BeatAnalysis _remember(String key, BeatAnalysis analysis) {
    _memory.remove(key);
    _memory[key] = analysis;
    while (_memory.length > _memoryEntries) {
      _memory.remove(_memory.keys.first);
    }
    return analysis;
  }

  Future<Directory?> _dir() async {
    if (_directory != null) return _directory;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, "automix"));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return _directory = dir;
    } catch (_) {
      return null;
    }
  }

  static String _fileName(String key) => "${key.replaceAll(RegExp(r"[^A-Za-z0-9_.-]"), "_")}.json";

  Future<BeatAnalysis?> _readDisk(String key) async {
    final dir = await _dir();
    if (dir == null) return null;
    final file = File(p.join(dir.path, _fileName(key)));
    if (!file.existsSync()) return null;
    try {
      return BeatAnalysis.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String key, BeatAnalysis analysis) async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      await File(p.join(dir.path, _fileName(key))).writeAsString(jsonEncode(analysis.toJson()));
    } catch (_) {}
  }
}
