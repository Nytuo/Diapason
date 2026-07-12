import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/spectrum_binner.dart';
import 'package:diapason/services/spectrum_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the byte layout Android's Visualizer.getFft() hands back: [0] is the
/// real DC term, [1] the real Nyquist term, then interleaved real/imaginary
/// pairs. A pure tone is one bin at full scale.
Uint8List androidFft({required int points, required int toneBin, int amplitude = 120}) {
  final bytes = Int8List(points * 2);
  bytes[toneBin * 2] = amplitude; // real
  bytes[toneBin * 2 + 1] = 0; // imaginary
  return bytes.buffer.asUint8List();
}

/// Index of the largest band.
int peakOf(Float32List bands) {
  var peak = 0;
  for (var i = 1; i < bands.length; i++) {
    if (bands[i] > bands[peak]) peak = i;
  }
  return peak;
}

void main() {
  const sampleRate = 44100;
  const points = 512; // a 1024-byte capture

  /// Frequency that FFT point [i] represents.
  double hzOf(int i) => i / points * (sampleRate / 2);

  SpectrumFrame frameWithToneAt(int bin) =>
      SpectrumFrame(AndroidVisualizerSource.magnitudesForTest(androidFft(points: points, toneBin: bin)), sampleRate);

  group("Android FFT unpacking", () {
    test("puts the tone's energy in the bin it belongs to, and nowhere else", () {
      final magnitudes = AndroidVisualizerSource.magnitudesForTest(androidFft(points: points, toneBin: 40));

      expect(magnitudes.length, points);
      expect(magnitudes[40], greaterThan(0.5));
      for (var i = 0; i < points; i++) {
        if (i != 40) expect(magnitudes[i], 0.0, reason: "bin $i should be silent");
      }
    });

    test("combines real and imaginary parts", () {
      final bytes = Int8List(points * 2);
      bytes[20] = 60;
      bytes[21] = 60; // equal real and imaginary => magnitude 60*sqrt(2)
      final magnitudes = AndroidVisualizerSource.magnitudesForTest(bytes.buffer.asUint8List());

      expect(magnitudes[10], closeTo(60 * sqrt(2) / 181.0, 0.01));
    });
  });

  group("binning", () {
    test("a low tone peaks in a low band, a high tone in a high band", () {
      final bands = Float32List(64);

      binFrame(frameWithToneAt(3), bands, minHz: 20, maxHz: 16000, dbFloor: -100, dbCeiling: -10, logScale: true);
      final lowPeak = peakOf(bands);

      binFrame(frameWithToneAt(300), bands, minHz: 20, maxHz: 16000, dbFloor: -100, dbCeiling: -10, logScale: true);
      final highPeak = peakOf(bands);

      expect(lowPeak, lessThan(highPeak), reason: "${hzOf(3)}Hz should sit left of ${hzOf(300)}Hz");
      expect(lowPeak, lessThan(20));
      expect(highPeak, greaterThan(40));
    });

    test("log spacing gives low frequencies more bands than linear spacing does", () {
      // A 258 Hz tone: musically central, but only 1.2% of the way to Nyquist.
      final tone = frameWithToneAt(6);
      final bands = Float32List(64);

      binFrame(tone, bands, minHz: 20, maxHz: 16000, dbFloor: -100, dbCeiling: -10, logScale: true);
      final logPeak = peakOf(bands);

      binFrame(tone, bands, minHz: 20, maxHz: 16000, dbFloor: -100, dbCeiling: -10, logScale: false);
      final linearPeak = peakOf(bands);

      // Linear spacing crams it into the leftmost band; log spacing spreads it out.
      expect(linearPeak, lessThanOrEqualTo(1));
      expect(logPeak, greaterThan(linearPeak));
    });

    test("silence maps to a flat curve", () {
      final bands = Float32List(64);
      binFrame(
        SpectrumFrame(Float32List(points), sampleRate),
        bands,
        minHz: 20,
        maxHz: 16000,
        dbFloor: -100,
        dbCeiling: -10,
        logScale: true,
      );

      expect(bands.every((b) => b == 0.0), isTrue);
    });

    test("every band stays within 0..1 no matter the dB window", () {
      final bands = Float32List(64);
      binFrame(frameWithToneAt(100), bands, minHz: 20, maxHz: 16000, dbFloor: -20, dbCeiling: -18, logScale: true);

      expect(bands.every((b) => b >= 0.0 && b <= 1.0), isTrue);
    });
  });
}
