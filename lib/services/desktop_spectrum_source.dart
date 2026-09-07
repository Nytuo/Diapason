import 'dart:async';
import 'dart:typed_data';

import 'package:diapason/services/pcm_capture.dart';
import 'package:diapason/services/spectrum_source.dart';
import 'package:diapason/utils/fft.dart';

class DesktopSpectrumSource implements SpectrumSource {
  DesktopSpectrumSource({required this.backend, required int fps, this.fftSize = 2048})
    : assert(fftSize > 1 && (fftSize & (fftSize - 1)) == 0, "fftSize must be a power of two"),
      _minFrameGap = Duration(microseconds: (1000000 / fps.clamp(1, 120)).round()),
      _fft = RealFft(fftSize),
      _ring = Float32List(fftSize),
      _window = Float32List(fftSize),
      _magnitudes = Float32List(fftSize ~/ 2);

  final PcmCaptureBackend backend;
  final int fftSize;
  final Duration _minFrameGap;

  final RealFft _fft;

  final Float32List _ring;
  int _writePos = 0;
  int _filled = 0;

  final Float32List _window;
  final Float32List _magnitudes;

  int _sampleRate = 44100;
  final _stopwatch = Stopwatch();
  Duration? _lastEmit;

  final _controller = StreamController<SpectrumFrame>.broadcast();
  StreamSubscription<PcmChunk>? _subscription;

  @override
  Stream<SpectrumFrame> get frames => _controller.stream;

  @override
  Future<bool> start() async {
    if (!await backend.start()) return false;
    _stopwatch.start();
    _subscription = backend.chunks.listen(_onChunk);
    return true;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _stopwatch.stop();
    await backend.stop();
  }

  void _onChunk(PcmChunk chunk) {
    _sampleRate = chunk.sampleRate;
    _appendMono(chunk);

    if (_filled < fftSize) return;
    final now = _stopwatch.elapsed;
    final last = _lastEmit;
    if (last != null && now - last < _minFrameGap) return;
    _lastEmit = now;

    _linearise(_window);
    _fft.magnitudes(_window, _magnitudes);
    _controller.add(SpectrumFrame(Float32List.fromList(_magnitudes), _sampleRate));
  }

  void _appendMono(PcmChunk chunk) {
    final samples = chunk.samples;
    final channels = chunk.channels;
    final frameCount = samples.length ~/ channels;
    final inv = 1.0 / channels;
    for (var f = 0; f < frameCount; f++) {
      var sum = 0.0;
      final base = f * channels;
      for (var c = 0; c < channels; c++) {
        sum += samples[base + c];
      }
      _ring[_writePos] = sum * inv;
      _writePos = (_writePos + 1) % fftSize;
      if (_filled < fftSize) _filled++;
    }
  }

  void _linearise(Float32List out) {
    final start = _writePos;
    for (var i = 0; i < fftSize; i++) {
      out[i] = _ring[(start + i) % fftSize];
    }
  }
}
