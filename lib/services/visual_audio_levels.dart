import 'dart:async';

import 'package:diapason/utils/platform.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/spectrum_binner.dart';
import 'package:diapason/services/spectrum_source.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Bass, mid and treble energy (0..1) of what is playing, for the animated visuals.
///
/// Reads the same native spectrum as the spectrum visualizer through [SpectrumHub], so both can run at once. Call
/// [update] once per drawn frame; with no source (Android without the microphone permission, an HLS stream on Apple
/// platforms...) [receiving] stays false and the levels stay at 0.
class VisualAudioLevels {
  VisualAudioLevels({SpectrumHub? hub}) : _hub = hub ?? SpectrumHub.instance;

  static final _log = Logger("VisualAudioLevels");

  static const bandCount = 24;
  static const _staleAfter = Duration(milliseconds: 300);

  final SpectrumHub _hub;
  final _bands = Float32List(bandCount);

  Object? _token;
  StreamSubscription<SpectrumFrame>? _frames;
  StreamSubscription<int?>? _session;
  SpectrumFrame? _latest;
  final _sinceLatest = Stopwatch();
  int _generation = 0;

  /// Whether the native source is running.
  final receiving = ValueNotifier<bool>(false);

  double bass = 0;
  double mid = 0;
  double treble = 0;

  /// A short kick when the bass jumps above its recent average.
  double beat = 0;
  double _bassAverage = 0;

  /// Starts listening; on Android, follows the player's audio session.
  void start({required int fps}) {
    if (!spectrumSourceAvailable) return;
    if (Platform.isAndroid && GetIt.instance.isRegistered<MusicPlayerBackgroundTask>()) {
      _session ??= GetIt.instance<MusicPlayerBackgroundTask>().androidAudioSessionIdStream.distinct().listen(
        (id) => _attach(id, fps),
      );
    } else {
      unawaited(_attach(null, fps));
    }
  }

  Future<void> _attach(int? sessionId, int fps) async {
    final generation = ++_generation;
    await _detach();
    if (Platform.isAndroid && sessionId == null) return;
    final token = Object();
    _token = token;
    final flowing = await _hub.acquire(token, androidSessionId: sessionId, fps: fps);
    if (generation != _generation) return;
    if (!flowing) {
      _log.fine("No spectrum source for the animated visual");
      return;
    }
    _frames = _hub.frames.listen((frame) {
      _latest = frame;
      _sinceLatest
        ..reset()
        ..start();
    });
    receiving.value = true;
  }

  Future<void> _detach() async {
    await _frames?.cancel();
    _frames = null;
    final token = _token;
    _token = null;
    if (token != null) await _hub.release(token);
    _latest = null;
    receiving.value = false;
  }

  Future<void> stop() async {
    _generation++;
    await _session?.cancel();
    _session = null;
    await _detach();
  }

  void dispose() {
    unawaited(stop());
    receiving.dispose();
  }

  /// Advances the levels by [dt] seconds.
  void update(double dt) {
    final frame = _latest;
    final fresh = frame != null && _sinceLatest.elapsed < _staleAfter;
    double rawBass = 0, rawMid = 0, rawTreble = 0;
    if (fresh) {
      final s = FinampSettingsHelper.finampSettings;
      binFrame(
        frame,
        _bands,
        minHz: s.visualizerMinHz,
        maxHz: s.visualizerMaxHz,
        dbFloor: s.visualizerDbFloor,
        dbCeiling: s.visualizerDbCeiling,
        logScale: s.visualizerLogScale,
      );
      (rawBass, rawMid, rawTreble) = splitBands(_bands);
    }
    bass = _follow(bass, rawBass, dt);
    mid = _follow(mid, rawMid, dt);
    treble = _follow(treble, rawTreble, dt);
    _bassAverage += (bass - _bassAverage) * min(1.0, dt * 1.5);
    final kick = (bass - _bassAverage * 1.15) * 3;
    beat = kick > beat ? kick.clamp(0.0, 1.0) : max(0.0, beat - dt * 2.5);
  }

  /// Quick attack, slower release, frame-rate independent.
  static double _follow(double current, double target, double dt) {
    final rate = target > current ? 18.0 : 4.0;
    return current + (target - current) * min(1.0, dt * rate);
  }

  /// Mean of the low quarter, the middle half and the top quarter of [bands].
  @visibleForTesting
  static (double, double, double) splitBands(Float32List bands) {
    final n = bands.length;
    if (n == 0) return (0, 0, 0);
    final lowEnd = max(1, n ~/ 4);
    final midEnd = max(lowEnd + 1, (n * 3) ~/ 4).clamp(0, n);
    double mean(int from, int to) {
      if (to <= from) return 0;
      var sum = 0.0;
      for (var i = from; i < to; i++) {
        sum += bands[i];
      }
      return (sum / (to - from)).clamp(0.0, 1.0);
    }

    return (mean(0, lowEnd), mean(lowEnd, midEnd), mean(midEnd, n));
  }
}
