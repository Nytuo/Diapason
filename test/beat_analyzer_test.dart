import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/automix/beat_analyzer.dart';
import 'package:diapason/services/automix/mpv_pcm_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

const sr = 11025;

/// A kick on every bar's first beat, a hat on the others, after [silence] seconds of nothing.
Float32List clickTrack(double bpm, {double seconds = 40, double silence = 0.37, double tailSilence = 0}) {
  final out = Float32List((sr * seconds).round());
  for (var b = 0; silence + b * 60 / bpm < seconds - tailSilence; b++) {
    final start = ((silence + b * 60 / bpm) * sr).round();
    for (var i = 0; i < 400 && start + i < out.length; i++) {
      final env = exp(-i / 60);
      out[start + i] += (b % 4 == 0 ? 0.9 : 0.4) * env * sin(2 * pi * (b % 4 == 0 ? 60 : 900) * i / sr);
    }
  }
  return out;
}

void main() {
  test("finds the tempo, the beats and the bars of a steady beat", () {
    final a = BeatAnalyzer.analyze(clickTrack(128), sampleRate: sr, offset: 100);
    expect(a.bpm, closeTo(128, 1.5));
    expect(a.hasTempo, isTrue);
    expect(a.windowStart, 100);
    // Beats land on the clicks, in track time. (Within a few frames: every track is read with the same small bias,
    // so it cancels out when two are matched.)
    expect(a.beats.first, closeTo(100.37, 0.05));
    for (var i = 1; i < a.beats.length; i++) {
      expect(a.beats[i] - a.beats[i - 1], closeTo(60 / 128, 0.03));
    }
    // Bars start on the kicks.
    expect(a.downbeats.first, closeTo(100.37, 0.05));
    expect(a.downbeats[1] - a.downbeats[0], closeTo(4 * 60 / 128, 0.05));
  });

  test("works across the usual tempo range (fast tempos may read as half, which Automix treats as the same)", () {
    for (final bpm in [90.0, 105.0, 140.0, 174.0]) {
      final found = BeatAnalyzer.analyze(clickTrack(bpm), sampleRate: sr).bpm;
      final normalised = (found - bpm).abs() < (found * 2 - bpm).abs() ? found : found * 2;
      expect(normalised, closeTo(bpm, bpm * 0.02), reason: "$bpm BPM read as $found");
    }
  });

  test("knows where the music starts and stops", () {
    final a = BeatAnalyzer.analyze(clickTrack(120, silence: 3, tailSilence: 6), sampleRate: sr);
    expect(a.musicStart, closeTo(3, 0.3));
    expect(a.musicEnd!, lessThan(35));
  });

  test("no beat in noise or a sustained pad", () {
    final rng = Random(1);
    final noise = Float32List(sr * 30);
    for (var i = 0; i < noise.length; i++) {
      noise[i] = (rng.nextDouble() * 2 - 1) * 0.3;
    }
    final pad = Float32List(sr * 30);
    for (var i = 0; i < pad.length; i++) {
      final t = i / sr;
      pad[i] = 0.3 * sin(2 * pi * 220 * t) * (0.6 + 0.4 * sin(2 * pi * 0.13 * t)) + 0.2 * sin(2 * pi * 330.5 * t);
    }
    expect(BeatAnalyzer.analyze(noise, sampleRate: sr).hasTempo, isFalse);
    expect(BeatAnalyzer.analyze(pad, sampleRate: sr).hasTempo, isFalse);
    expect(BeatAnalyzer.analyze(Float32List(sr * 30), sampleRate: sr).hasTempo, isFalse);
  });

  test("too little audio is no analysis, not an error", () {
    expect(BeatAnalyzer.analyze(Float32List(sr), sampleRate: sr).hasTempo, isFalse);
  });

  test("phase is a fractional beat index", () {
    const beats = [10.0, 10.5, 11.0, 11.5];
    expect(BeatAnalysis.phaseIn(beats, 10.25), closeTo(0.5, 1e-9));
    expect(BeatAnalysis.phaseIn(beats, 11.5), closeTo(3, 1e-9));
    expect(BeatAnalysis.phaseIn(beats, 12.0), closeTo(4, 1e-9));
    expect(BeatAnalysis.phaseIn(beats, 9.5), closeTo(-1, 1e-9));
  });

  test("survives a round trip through JSON (the disk cache)", () {
    final a = BeatAnalyzer.analyze(clickTrack(128), sampleRate: sr, offset: 5);
    final b = BeatAnalysis.fromJson(a.toJson());
    expect(b.bpm, a.bpm);
    expect(b.beats, a.beats);
    expect(b.musicEnd, a.musicEnd);
  });

  test("reads the WAV mpv writes, even when its sizes were never filled in", () {
    final samples = [0, 16384, -16384, 32767];
    final bytes = BytesBuilder();
    void str(String s) => bytes.add(s.codeUnits);
    void u32(int v) => bytes.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
    void u16(int v) => bytes.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
    str("RIFF");
    u32(0xFFFFFFFF);
    str("WAVEfmt ");
    u32(16);
    u16(1);
    u16(1);
    u32(sr);
    u32(sr * 2);
    u16(2);
    u16(16);
    str("data");
    u32(0xFFFFFFFF);
    for (final s in samples) {
      bytes.add((ByteData(2)..setInt16(0, s, Endian.little)).buffer.asUint8List());
    }
    final out = MpvPcmDecoder.readWav16(bytes.toBytes())!;
    expect(out, hasLength(4));
    expect(out[1], closeTo(0.5, 1e-6));
    expect(out[2], closeTo(-0.5, 1e-6));
  });
}
