import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:diapason/components/PlayerScreen/spectrum_painter.dart';
import 'package:diapason/components/PlayerScreen/spectrum_visualizer.dart';
import 'package:diapason/components/visuals/milkdrop_view.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/visual_audio_levels.dart';
import 'package:diapason/services/waveform_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("WaveformService.computePeaks", () {
    test("folds samples into normalised bins", () {
      // A quiet first half, a loud second half.
      final samples = Float32List(10000);
      for (var i = 0; i < samples.length; i++) {
        final amplitude = i < 5000 ? 0.1 : 0.8;
        samples[i] = amplitude * sin(i * 0.3);
      }
      final peaks = WaveformService.computePeaks(samples, 100);
      expect(peaks.length, 100);
      expect(peaks.every((v) => v >= 0 && v <= 1), isTrue);
      expect(peaks[80], closeTo(1.0, 0.05));
      expect(peaks[20], lessThan(0.3));
    });

    test("silence gives zeros, not NaN", () {
      final peaks = WaveformService.computePeaks(Float32List(1000), 50);
      expect(peaks.every((v) => v == 0), isTrue);
    });

    test("fewer samples than bins still fills every bin", () {
      final peaks = WaveformService.computePeaks(Float32List.fromList([0.5, -0.5, 0.25]), 10);
      expect(peaks.length, 10);
      expect(peaks.any((v) => v.isNaN), isFalse);
    });

    test("one long track stays fast enough", () {
      // 10 minutes at the service's lowest rate for such a track.
      final samples = Float32List(4000000);
      final random = Random(1);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = random.nextDouble() * 2 - 1;
      }
      final watch = Stopwatch()..start();
      WaveformService.computePeaks(samples, WaveformService.binCount);
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });
  });

  test("VisualAudioLevels.splitBands averages low, mid and high", () {
    final bands = Float32List.fromList([1, 1, 0, 0, 0.5, 0.5, 0, 0]);
    final (bass, mid, treble) = VisualAudioLevels.splitBands(bands);
    expect(bass, 1);
    expect(mid, 0.25);
    expect(treble, 0);
  });

  test("MilkdropShader.presetFor cycles only when the setting is -1", () {
    expect(MilkdropShader.presetFor(2, const Duration(minutes: 5)), MilkdropPreset.tunnel);
    expect(MilkdropShader.presetFor(-1, Duration.zero), MilkdropPreset.plasma);
    expect(MilkdropShader.presetFor(-1, const Duration(seconds: 31)), MilkdropPreset.kaleidoscope);
    expect(MilkdropShader.presetFor(-1, const Duration(seconds: 30 * 5)), MilkdropPreset.plasma);
  });

  test("the radial style is drawn around the cover only", () {
    expect(SpectrumVisualizer.effectiveStyle(VisualizerStyle.radial, SpectrumPlacement.background), isNull);
    expect(
      SpectrumVisualizer.effectiveStyle(VisualizerStyle.radial, SpectrumPlacement.aroundCover),
      VisualizerStyle.radial,
    );
    expect(
      SpectrumVisualizer.effectiveStyle(VisualizerStyle.radial, SpectrumPlacement.strip),
      VisualizerStyle.mirroredBars,
    );
    expect(SpectrumVisualizer.effectiveStyle(VisualizerStyle.bars, SpectrumPlacement.aroundCover), isNull);
    expect(SpectrumVisualizer.effectiveStyle(VisualizerStyle.wave, SpectrumPlacement.background), VisualizerStyle.wave);
  });

  test("every style paints", () {
    final bars = SpectrumBars()..values = Float32List.fromList(List.generate(48, (i) => (i % 7) / 7));
    for (var i = 0; i < 10; i++) {
      bars.advance(1 / 30);
    }
    for (final style in VisualizerStyle.values) {
      final painter = SpectrumPainter(
        bars: bars,
        repaint: ValueNotifier(0),
        style: style,
        accent: Colors.teal,
        scale: 1,
        bottomOpacity: 0.2,
        topOpacity: 0.6,
        useSplines: true,
        strokeWidth: 2,
        fillEnabled: true,
      );
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(400, 200));
      recorder.endRecording().dispose();
    }
  });

  test("the animated visual's shader loads, takes its uniforms and renders with feedback", () async {
    final program = await ui.FragmentProgram.fromAsset("shaders/milkdrop.frag");
    final shader = program.fragmentShader();
    ui.Image? previous;
    for (var frame = 0; frame < 3; frame++) {
      final recorder = ui.PictureRecorder();
      final blank = previous ?? _blank();
      var i = 0;
      shader
        ..setFloat(i++, 64)
        ..setFloat(i++, 48)
        ..setFloat(i++, frame / 30)
        ..setFloat(i++, 0.5)
        ..setFloat(i++, 0.3)
        ..setFloat(i++, 0.2)
        ..setFloat(i++, 0.1)
        ..setFloat(i++, frame.toDouble())
        ..setFloat(i++, previous == null ? 0 : 1)
        ..setFloat(i++, 0.2)
        ..setFloat(i++, 0.6)
        ..setFloat(i++, 0.9)
        ..setImageSampler(0, blank);
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 64, 48), Paint()..shader = shader);
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 48);
      picture.dispose();
      previous?.dispose();
      previous = image;
    }
    expect(previous!.width, 64);
  });
}

ui.Image _blank() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint()..color = Colors.black);
  return recorder.endRecording().toImageSync(1, 1);
}
