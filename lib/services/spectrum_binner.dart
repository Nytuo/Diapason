import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/spectrum_source.dart';

void binFrame(
  SpectrumFrame frame,
  Float32List out, {
  required double minHz,
  required double maxHz,
  required double dbFloor,
  required double dbCeiling,
  required bool logScale,
}) {
  final bandCount = out.length;
  final pointCount = frame.magnitudes.length;
  if (bandCount == 0 || pointCount == 0) return;

  final nyquist = frame.sampleRate / 2;
  final range = max(dbCeiling - dbFloor, 1.0);

  int hzToIndex(double hz) => (hz / nyquist * pointCount).round().clamp(0, pointCount - 1);

  final lmin = logScale ? _ln(max(1.0, minHz)) : 0.0;
  final lmax = logScale ? _ln(max(minHz + 1, maxHz)) : 0.0;

  for (var b = 0; b < bandCount; b++) {
    final t0 = b / bandCount;
    final t1 = (b + 1) / bandCount;

    final double f0, f1;
    if (logScale) {
      f0 = exp(lmin + (lmax - lmin) * t0);
      f1 = exp(lmin + (lmax - lmin) * t1);
    } else {
      f0 = minHz + (maxHz - minHz) * t0;
      f1 = minHz + (maxHz - minHz) * t1;
    }

    final i0 = hzToIndex(f0);
    final i1 = max(i0 + 1, hzToIndex(f1));

    var sum = 0.0;
    var n = 0;
    for (var i = i0; i < i1 && i < pointCount; i++) {
      sum += frame.magnitudes[i];
      n++;
    }
    if (n == 0) {
      out[b] = 0;
      continue;
    }

    final mean = sum / n;
    final db = 20 * (_log10(max(mean, 1e-6)));
    out[b] = ((db - dbFloor) / range).clamp(0.0, 1.0);
  }
}

double _ln(double x) => log(x);

double _log10(double x) => log(x) / ln10;
