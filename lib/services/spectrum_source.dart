import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'package:diapason/services/desktop_spectrum_source.dart';
import 'package:diapason/services/pcm_capture.dart';

/// One FFT frame: linear magnitudes in 0..1, one per frequency point, evenly
/// spaced from 0 Hz to [sampleRate] / 2.
class SpectrumFrame {
  const SpectrumFrame(this.magnitudes, this.sampleRate);

  final Float32List magnitudes;
  final int sampleRate;
}

abstract class SpectrumSource {
  Stream<SpectrumFrame> get frames;

  Future<bool> start();

  Future<void> stop();
}

bool get spectrumSourceAvailable =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux;

SpectrumSource? createSpectrumSource({int? androidSessionId, required int fps}) {
  if (Platform.isAndroid) {
    return androidSessionId == null ? null : AndroidVisualizerSource(sessionId: androidSessionId, fps: fps);
  }
  if (Platform.isIOS || Platform.isMacOS) return DarwinSpectrumTapSource();
  if (Platform.isWindows || Platform.isLinux) {
    return DesktopSpectrumSource(backend: NativeLoopbackPcmCapture(), fps: fps);
  }
  return null;
}

/// Runs at most one native [SpectrumSource] and hands its frames to every visualizer on screen.
///
/// The native sources sit on process-wide channels: two of them would fight over the same tap, and stopping one
/// would silence the other. Visualizers register with [acquire] and leave with [release]; the source starts with the
/// first holder and stops with the last one.
class SpectrumHub {
  SpectrumHub._({SpectrumSource? Function({int? androidSessionId, required int fps})? factory})
    : _factory = factory ?? createSpectrumSource;

  static final instance = SpectrumHub._();

  @visibleForTesting
  factory SpectrumHub.forTest(SpectrumSource? Function({int? androidSessionId, required int fps}) factory) =>
      SpectrumHub._(factory: factory);

  static final _logger = Logger("SpectrumHub");

  final SpectrumSource? Function({int? androidSessionId, required int fps}) _factory;
  final _frames = StreamController<SpectrumFrame>.broadcast();

  /// What each holder asked for: the Android audio session (null elsewhere) and the frame rate.
  final _holders = <Object, (int?, int)>{};

  SpectrumSource? _source;
  StreamSubscription<SpectrumFrame>? _sourceSubscription;
  (int?, int)? _running;

  /// Start/stop calls are chained so overlapping acquires and releases never run two native sources at once.
  Future<void> _queue = Future.value();

  Stream<SpectrumFrame> get frames => _frames.stream;

  @visibleForTesting
  bool get isRunning => _source != null;

  /// Registers [holder] and makes sure a source is running for this session and frame rate. The most recent request
  /// wins: every visualizer reads the same settings and session, so they only disagree for a moment.
  ///
  /// Returns whether frames will flow.
  Future<bool> acquire(Object holder, {int? androidSessionId, required int fps}) {
    final config = (androidSessionId, fps);
    _holders[holder] = config;
    return _serialized(() => _reconcile(config));
  }

  /// Unregisters [holder]; the source stops once nobody holds it.
  Future<void> release(Object holder) async {
    if (_holders.remove(holder) == null) return;
    await _serialized(() => _reconcile(_holders.isEmpty ? null : _holders.values.last));
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<bool> _reconcile((int?, int)? desired) async {
    if (desired != null && desired == _running && _source != null) return true;

    await _sourceSubscription?.cancel();
    _sourceSubscription = null;
    await _source?.stop();
    _source = null;
    _running = null;
    if (desired == null) return false;

    final source = _factory(androidSessionId: desired.$1, fps: desired.$2);
    if (source == null) return false;
    if (!await source.start()) {
      _logger.info("No spectrum source available");
      return false;
    }
    _source = source;
    _running = desired;
    _sourceSubscription = source.frames.listen(_frames.add);
    return true;
  }
}

/// Reads FFT frames from the MTAudioProcessingTap in just_audio's darwin engine.
/// See SpectrumTap.m in the fork.
///
/// The tap is installed by the plugin and computes nothing until this stream is
/// listened to, so starting is only a matter of subscribing. Frames arrive at
/// sampleRate / 1024 per second (~43 Hz at 44.1 kHz) — faster than Android, and
/// faster than we redraw, so the widget's own frame limiter still governs.
///
/// One real limitation: an audio mix cannot attach to an HLS stream. If a track
/// is served as HLS the tap sends nothing, and the curve stays hidden.
class DarwinSpectrumTapSource implements SpectrumSource {
  static const _events = EventChannel("com.ryanheise.just_audio.spectrum");

  static final _logger = Logger("DarwinSpectrumTapSource");

  final _controller = StreamController<SpectrumFrame>.broadcast();
  StreamSubscription<dynamic>? _subscription;

  @override
  Stream<SpectrumFrame> get frames => _controller.stream;

  @override
  Future<bool> start() async {
    _subscription = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final magnitudes = event["magnitudes"];
      final sampleRate = event["sampleRate"];
      if (magnitudes is! Float32List || sampleRate is! int) return;
      _controller.add(SpectrumFrame(magnitudes, sampleRate));
    }, onError: (Object e) => _logger.warning("Spectrum tap stream error: $e"));

    return true;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

class AndroidVisualizerSource implements SpectrumSource {
  AndroidVisualizerSource({required this.sessionId, required this.fps});

  static const _methods = MethodChannel("fr.nytuo.diapason/visualizer");
  static const _events = EventChannel("fr.nytuo.diapason/visualizer_fft");

  static final _logger = Logger("AndroidVisualizerSource");

  final int sessionId;

  final int fps;

  /// Bytes per FFT frame. 1024 gives 512 frequency points, plenty for 64 bands.
  static const _captureSize = 1024;

  final _controller = StreamController<SpectrumFrame>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  int _sampleRate = 44100;

  @override
  Stream<SpectrumFrame> get frames => _controller.stream;

  @override
  Future<bool> start() async {
    try {
      final granted = await _methods.invokeMapMethod<String, dynamic>("start", {
        "sessionId": sessionId,
        "captureSize": _captureSize,
        "fps": fps,
      });
      _sampleRate = ((granted?["samplingRate"] as int? ?? 44100000) / 1000).round();
    } on PlatformException catch (e) {
      _logger.warning("Could not start the platform visualizer: ${e.message}");
      return false;
    }

    _subscription = _events.receiveBroadcastStream().listen((event) {
      if (event is! Uint8List) return;
      _controller.add(SpectrumFrame(_magnitudes(event), _sampleRate));
    }, onError: (Object e) => _logger.warning("Visualizer stream error: $e"));

    return true;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methods.invokeMethod("stop");
    } on PlatformException catch (e) {
      _logger.warning("Could not stop the platform visualizer: ${e.message}");
    }
  }

  void dispose() {
    _controller.close();
  }

  @visibleForTesting
  static Float32List magnitudesForTest(Uint8List fft) => _magnitudes(fft);

  /// Converts Android's packed FFT layout into linear magnitudes in 0..1.
  ///
  /// The platform hands back signed bytes as: [0] real DC, [1] real Nyquist,
  /// then interleaved real/imaginary pairs for every bin in between.
  static Float32List _magnitudes(Uint8List fft) {
    final n = fft.length ~/ 2;
    final out = Float32List(n);
    final bytes = fft.buffer.asInt8List(fft.offsetInBytes, fft.length);

    out[0] = (bytes[0].abs()) / 128.0;
    for (var i = 1; i < n; i++) {
      final re = bytes[i * 2].toDouble();
      final im = bytes[i * 2 + 1].toDouble();
      out[i] = min(sqrt(re * re + im * im) / 181.0, 1.0);
    }
    return out;
  }
}
