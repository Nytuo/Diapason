import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/desktop_spectrum_source.dart';
import 'package:diapason/services/pcm_capture.dart';
import 'package:diapason/services/spectrum_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePcmBackend implements PcmCaptureBackend {
  final _controller = StreamController<PcmChunk>.broadcast();
  bool started = false;

  @override
  Stream<PcmChunk> get chunks => _controller.stream;

  @override
  Future<bool> start() async {
    started = true;
    return true;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  void push(PcmChunk chunk) => _controller.add(chunk);
}

class _FailingBackend implements PcmCaptureBackend {
  @override
  Stream<PcmChunk> get chunks => const Stream.empty();
  @override
  Future<bool> start() async => false;
  @override
  Future<void> stop() async {}
}

PcmChunk _stereoSine(double freq, int sampleRate, int frames) {
  final samples = Float32List(frames * 2);
  for (var i = 0; i < frames; i++) {
    final v = sin(2 * pi * freq * i / sampleRate);
    samples[i * 2] = v;
    samples[i * 2 + 1] = v;
  }
  return PcmChunk(samples, sampleRate, 2);
}

void main() {
  group('DesktopSpectrumSource', () {
    test('start() fails when the backend cannot capture', () async {
      final source = DesktopSpectrumSource(backend: _FailingBackend(), fps: 30);
      expect(await source.start(), isFalse);
    });

    test('emits a spectrum frame peaking at the tone frequency', () async {
      const sampleRate = 44100;
      const fftSize = 2048;
      const bin = 120;
      const freq = bin * sampleRate / fftSize;

      final backend = _FakePcmBackend();
      final source = DesktopSpectrumSource(backend: backend, fps: 30, fftSize: fftSize);
      expect(await source.start(), isTrue);

      final frameFuture = source.frames.first;

      backend.push(_stereoSine(freq, sampleRate, fftSize));
      backend.push(_stereoSine(freq, sampleRate, fftSize));

      final frame = await frameFuture.timeout(const Duration(seconds: 1));
      expect(frame.sampleRate, sampleRate);
      expect(frame.magnitudes.length, fftSize ~/ 2);

      var peakBin = 0;
      var peak = 0.0;
      for (var i = 0; i < frame.magnitudes.length; i++) {
        if (frame.magnitudes[i] > peak) {
          peak = frame.magnitudes[i];
          peakBin = i;
        }
      }
      expect((peakBin - bin).abs(), lessThanOrEqualTo(1));
      expect(peak, greaterThan(0.5));

      await source.stop();
      expect(backend.started, isFalse);
    });

    test('emitted frames do not alias the internal scratch buffer', () async {
      const sampleRate = 44100;
      const fftSize = 2048;
      final backend = _FakePcmBackend();
      final source = DesktopSpectrumSource(backend: backend, fps: 120, fftSize: fftSize);
      await source.start();

      final frames = <SpectrumFrame>[];
      final sub = source.frames.listen(frames.add);

      backend.push(_stereoSine(1000, sampleRate, fftSize));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      backend.push(_stereoSine(5000, sampleRate, fftSize));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(frames.length, greaterThanOrEqualTo(2));
      expect(frames.first.magnitudes, isNot(equals(frames.last.magnitudes)));

      await sub.cancel();
      await source.stop();
    });
  });
}
