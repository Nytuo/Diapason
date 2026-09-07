import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/utils/fft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RealFft', () {
    test('rejects non power-of-two sizes', () {
      expect(() => RealFft(1000), throwsA(isA<AssertionError>()));
    });

    test('a pure sine peaks in the expected bin', () {
      const size = 2048;
      const sampleRate = 44100;
      final fft = RealFft(size);

      const bin = 100;
      const freq = bin * sampleRate / size;

      final samples = Float32List(size);
      for (var i = 0; i < size; i++) {
        samples[i] = sin(2 * pi * freq * i / sampleRate);
      }

      final out = Float32List(size ~/ 2);
      fft.magnitudes(samples, out);

      var peakBin = 0;
      var peak = 0.0;
      for (var i = 0; i < out.length; i++) {
        if (out[i] > peak) {
          peak = out[i];
          peakBin = i;
        }
      }
      expect(peakBin, bin);
      expect(peak, greaterThan(0.7));
      expect(peak, lessThanOrEqualTo(1.0));
    });

    test('silence produces no energy', () {
      const size = 1024;
      final fft = RealFft(size);
      final out = Float32List(size ~/ 2);
      fft.magnitudes(Float32List(size), out);
      for (final v in out) {
        expect(v, 0.0);
      }
    });

    test('magnitudes are clamped to 0..1 even when clipping', () {
      const size = 512;
      final fft = RealFft(size);
      final samples = Float32List(size);
      for (var i = 0; i < size; i++) {
        samples[i] = i.isEven ? 4.0 : -4.0;
      }
      final out = Float32List(size ~/ 2);
      fft.magnitudes(samples, out);
      for (final v in out) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });
  });
}
