import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/utils/fft.dart';

/// What Automix knows about one stretch of a track (its start or its end): tempo, where every beat and bar falls,
/// and where the music actually starts and stops (as opposed to silence).
///
/// All times are seconds from the start of the track.
class BeatAnalysis {
  const BeatAnalysis({
    required this.bpm,
    required this.confidence,
    required this.beats,
    required this.downbeats,
    required this.windowStart,
    required this.windowEnd,
    this.musicStart,
    this.musicEnd,
  });

  static const empty = BeatAnalysis(bpm: 0, confidence: 0, beats: [], downbeats: [], windowStart: 0, windowEnd: 0);

  /// Below this the beat is too weak or irregular to match (ambient, rubato, spoken word).
  static const minConfidence = 0.12;

  final double bpm;

  /// 0..1: how periodic the onsets are at [bpm].
  final double confidence;

  final List<double> beats;

  /// The first beat of each bar (assuming 4/4).
  final List<double> downbeats;

  final double windowStart;
  final double windowEnd;

  /// First and last moments that are not (near) silence, within the window.
  final double? musicStart;
  final double? musicEnd;

  bool get hasTempo => bpm > 0 && confidence >= minConfidence && beats.length >= 8 && downbeats.length >= 2;

  double get period => bpm > 0 ? 60 / bpm : 0;

  /// The (fractional) beat index at [time], counting from the first detected beat. Extrapolated outside the beats.
  double phaseAt(double time) => phaseIn(beats, time);

  static double phaseIn(List<double> beats, double time) {
    if (beats.length < 2) return 0;
    if (time <= beats.first) return (time - beats.first) / (beats[1] - beats[0]);
    if (time >= beats.last) {
      final n = beats.length;
      return (n - 1) + (time - beats.last) / (beats[n - 1] - beats[n - 2]);
    }
    var lo = 0;
    var hi = beats.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (beats[mid] <= time) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo + (time - beats[lo]) / (beats[hi] - beats[lo]);
  }

  Map<String, dynamic> toJson() => {
    "bpm": bpm,
    "confidence": confidence,
    "beats": beats,
    "downbeats": downbeats,
    "windowStart": windowStart,
    "windowEnd": windowEnd,
    "musicStart": musicStart,
    "musicEnd": musicEnd,
  };

  factory BeatAnalysis.fromJson(Map<String, dynamic> json) {
    List<double> list(Object? v) => (v as List? ?? const []).map((e) => (e as num).toDouble()).toList();
    return BeatAnalysis(
      bpm: (json["bpm"] as num).toDouble(),
      confidence: (json["confidence"] as num).toDouble(),
      beats: list(json["beats"]),
      downbeats: list(json["downbeats"]),
      windowStart: (json["windowStart"] as num).toDouble(),
      windowEnd: (json["windowEnd"] as num).toDouble(),
      musicStart: (json["musicStart"] as num?)?.toDouble(),
      musicEnd: (json["musicEnd"] as num?)?.toDouble(),
    );
  }

  @override
  String toString() =>
      "BeatAnalysis(${bpm.toStringAsFixed(1)} BPM, confidence ${confidence.toStringAsFixed(2)}, "
      "${beats.length} beats, music ${musicStart?.toStringAsFixed(2)}–${musicEnd?.toStringAsFixed(2)})";
}

/// Classic beat tracking, sized to run in an isolate in well under a second for a minute of audio:
/// spectral-flux onsets → tempo by autocorrelation (with a prior around 120 BPM) → beats by dynamic programming
/// (Ellis, 2007) → downbeats from where the low end (kick) hits hardest.
class BeatAnalyzer {
  static const fftSize = 1024;
  static const hop = 128;
  static const _minBpm = 70.0;
  static const _maxBpm = 190.0;
  static const _tightness = 100.0;
  static const _minOnsetStrength = 2.0;

  /// [samples] is mono audio at [sampleRate] that starts [offset] seconds into the track.
  static BeatAnalysis analyze(Float32List samples, {required int sampleRate, double offset = 0}) {
    final windowEnd = offset + samples.length / sampleRate;
    final frames = samples.length < fftSize ? 0 : (samples.length - fftSize) ~/ hop + 1;
    final fps = sampleRate / hop;
    if (frames < fps * 6) {
      return BeatAnalysis(
        bpm: 0,
        confidence: 0,
        beats: const [],
        downbeats: const [],
        windowStart: offset,
        windowEnd: windowEnd,
      );
    }

    // --- Onset strength (spectral flux on log magnitudes), low-band flux, loudness ---------------------------
    final fft = RealFft(fftSize);
    final frame = Float32List(fftSize);
    final mags = Float32List(fftSize ~/ 2);
    final previous = Float32List(fftSize ~/ 2);
    final lowBins = (150 / (sampleRate / fftSize)).ceil();
    final onset = Float64List(frames);
    final low = Float64List(frames);
    final loudness = Float64List(frames);

    for (var f = 0; f < frames; f++) {
      final start = f * hop;
      var energy = 0.0;
      for (var i = 0; i < fftSize; i++) {
        final s = samples[start + i];
        frame[i] = s;
        energy += s * s;
      }
      loudness[f] = energy / fftSize;
      fft.magnitudes(frame, mags);
      var flux = 0.0;
      var lowFlux = 0.0;
      for (var b = 1; b < mags.length; b++) {
        final v = log(1 + 1000 * mags[b]);
        final d = v - previous[b];
        if (d > 0) {
          flux += d;
          if (b <= lowBins) lowFlux += d;
        }
        previous[b] = v;
      }
      onset[f] = f == 0 ? 0 : flux;
      low[f] = f == 0 ? 0 : lowFlux;
    }

    // How much the spectrum jumps at all. Real music scores ~10 and up; sustained pads and silence score below 1,
    // and there the normalised curve is just amplified numerical noise.
    final onsetStrength = _normaliseOnsets(onset, (fps * 0.4).round());

    // --- Tempo ------------------------------------------------------------------------------------------------
    final minLag = (fps * 60 / _maxBpm).floor();
    final maxLag = (fps * 60 / _minBpm).ceil();
    var ac0 = 0.0;
    for (var t = 0; t < frames; t++) {
      ac0 += onset[t] * onset[t];
    }
    if (ac0 <= 0 || maxLag >= frames ~/ 2) {
      return BeatAnalysis(
        bpm: 0,
        confidence: 0,
        beats: const [],
        downbeats: const [],
        windowStart: offset,
        windowEnd: windowEnd,
      );
    }

    final ac = Float64List(maxLag + 2);
    for (var lag = minLag - 1; lag <= maxLag + 1; lag++) {
      var sum = 0.0;
      for (var t = 0; t + lag < frames; t++) {
        sum += onset[t] * onset[t + lag];
      }
      // Unbiased: shorter overlaps are not penalised.
      ac[lag] = sum * frames / (frames - lag) / ac0;
    }

    double weighted(int lag) {
      final bpm = 60 * fps / lag;
      final octaves = log(bpm / 120) / ln2;
      return ac[lag] * exp(-0.5 * pow(octaves / 0.9, 2));
    }

    var best = minLag;
    for (var lag = minLag; lag <= maxLag; lag++) {
      if (weighted(lag) > weighted(best)) best = lag;
    }
    // Parabolic interpolation for a fractional lag.
    var period = best.toDouble();
    if (best > minLag && best < maxLag) {
      final a = weighted(best - 1);
      final b = weighted(best);
      final c = weighted(best + 1);
      final denominator = a - 2 * b + c;
      if (denominator.abs() > 1e-12) period = best + 0.5 * (a - c) / denominator;
    }
    final bpm = 60 * fps / period;
    // How much the beat lag stands out from the other lags: a steady beat has a sharp peak; noise is flat and low,
    // and a sustained pad is flat and high. Either way the contrast is small.
    final lags = [for (var lag = minLag; lag <= maxLag; lag++) ac[lag]]..sort();
    final median = lags[lags.length ~/ 2];
    final confidence = median >= 1 || onsetStrength < _minOnsetStrength
        ? 0.0
        : ((ac[best] - median) / (1 - median)).clamp(0.0, 1.0);

    // --- Beats (dynamic programming) --------------------------------------------------------------------------
    final score = Float64List(frames);
    final back = Int32List(frames);
    final minStep = (period / 2).round();
    final maxStep = (period * 2).round();
    for (var t = 0; t < frames; t++) {
      var bestPrev = -1;
      var bestScore = double.negativeInfinity;
      for (var tau = t - maxStep; tau <= t - minStep; tau++) {
        if (tau < 0) continue;
        final penalty = log((t - tau) / period);
        final s = score[tau] - _tightness * penalty * penalty;
        if (s > bestScore) {
          bestScore = s;
          bestPrev = tau;
        }
      }
      if (bestPrev >= 0 && bestScore > 0) {
        score[t] = onset[t] + bestScore;
        back[t] = bestPrev;
      } else {
        score[t] = onset[t];
        back[t] = -1;
      }
    }
    var end = frames - 1;
    for (var t = max(0, frames - period.round()); t < frames; t++) {
      if (score[t] > score[end]) end = t;
    }
    final beatFrames = <int>[];
    for (var t = end; t >= 0; t = back[t]) {
      beatFrames.add(t);
      if (back[t] < 0) break;
    }
    final orderedFrames = beatFrames.reversed.toList();
    double timeOf(num f) => offset + (f * hop + fftSize / 2) / sampleRate;
    final beats = [for (final f in orderedFrames) timeOf(f)];

    // --- Downbeats: the beat-of-four with the strongest low end ------------------------------------------------
    final downbeats = <double>[];
    if (beats.length >= 8) {
      final strength = List<double>.filled(4, 0);
      final counts = List<int>.filled(4, 0);
      for (var i = 0; i < orderedFrames.length; i++) {
        final f = orderedFrames[i];
        var peak = 0.0;
        for (var d = -2; d <= 2; d++) {
          final g = f + d;
          if (g >= 0 && g < frames && low[g] > peak) peak = low[g];
        }
        strength[i % 4] += peak;
        counts[i % 4]++;
      }
      var phase = 0;
      for (var k = 1; k < 4; k++) {
        if (strength[k] / max(1, counts[k]) > strength[phase] / max(1, counts[phase])) phase = k;
      }
      for (var i = phase; i < beats.length; i += 4) {
        downbeats.add(beats[i]);
      }
    }

    // --- Where the music is (not silence) -----------------------------------------------------------------------
    final smooth = _movingAverage(loudness, (fps * 0.25).round());
    final db = [for (final v in smooth) 10 * log(v + 1e-12) / ln10];
    final sorted = [...db]..sort();
    final reference = sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
    final threshold = max(reference - 24, -60.0);
    int? first;
    int? last;
    for (var f = 0; f < frames; f++) {
      if (db[f] >= threshold) {
        first ??= f;
        last = f;
      }
    }

    return BeatAnalysis(
      bpm: bpm,
      confidence: confidence,
      beats: beats,
      downbeats: downbeats,
      windowStart: offset,
      windowEnd: windowEnd,
      musicStart: first == null ? null : timeOf(first) - fftSize / 2 / sampleRate,
      musicEnd: last == null ? null : timeOf(last) + fftSize / 2 / sampleRate,
    );
  }

  /// Removes the slowly-varying part of the onset curve, keeps what pokes out, and scales it to unit deviation.
  static double _normaliseOnsets(Float64List onset, int window) {
    final mean = _movingAverage(onset, window);
    var sumSq = 0.0;
    for (var i = 0; i < onset.length; i++) {
      final v = onset[i] - mean[i];
      onset[i] = v > 0 ? v : 0;
      sumSq += onset[i] * onset[i];
    }
    final std = sqrt(sumSq / onset.length);
    if (std > 0) {
      for (var i = 0; i < onset.length; i++) {
        onset[i] /= std;
      }
    }
    return std;
  }

  static Float64List _movingAverage(Float64List input, int window) {
    final out = Float64List(input.length);
    final half = max(1, window ~/ 2);
    var sum = 0.0;
    var lo = 0;
    var hi = -1;
    for (var i = 0; i < input.length; i++) {
      final wantLo = max(0, i - half);
      final wantHi = min(input.length - 1, i + half);
      while (hi < wantHi) {
        sum += input[++hi];
      }
      while (lo < wantLo) {
        sum -= input[lo++];
      }
      out[i] = sum / (hi - lo + 1);
    }
    return out;
  }
}
