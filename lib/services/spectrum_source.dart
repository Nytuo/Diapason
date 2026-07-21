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
