import 'dart:async';
import 'dart:math';
import 'package:diapason/utils/platform.dart';
import 'dart:typed_data';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/components/PlayerScreen/spectrum_painter.dart';
import 'package:diapason/components/PlayerScreen/visualizer_style_tune.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/spectrum_binner.dart';
import 'package:diapason/services/spectrum_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Where a [SpectrumVisualizer] sits, which decides how the radial style (drawn around the cover) is handled.
enum SpectrumPlacement {
  /// Behind the player screen's controls: draws every style but the radial one, which [aroundCover] draws.
  background,

  /// A ring around the cover: draws only the radial style.
  aroundCover,

  /// A short strip (desktop player bar, fullscreen footer): the radial style falls back to mirrored bars.
  strip,

  /// The settings preview: draws every style, the radial one centred.
  preview,
}

/// The spectrum drawn behind the player's controls, in the style picked in the settings ([VisualizerStyle]).
class SpectrumVisualizer extends ConsumerStatefulWidget {
  const SpectrumVisualizer({super.key, this.placement = SpectrumPlacement.background});

  final SpectrumPlacement placement;

  /// The style actually drawn for [style] at [placement], or null when this placement shows nothing.
  static VisualizerStyle? effectiveStyle(VisualizerStyle style, SpectrumPlacement placement) {
    final radial = style == VisualizerStyle.radial;
    return switch (placement) {
      SpectrumPlacement.background => radial ? null : style,
      SpectrumPlacement.aroundCover => radial ? style : null,
      SpectrumPlacement.strip => radial ? VisualizerStyle.mirroredBars : style,
      SpectrumPlacement.preview => style,
    };
  }

  @override
  ConsumerState<SpectrumVisualizer> createState() => _SpectrumVisualizerState();
}

class _SpectrumVisualizerState extends ConsumerState<SpectrumVisualizer> with SingleTickerProviderStateMixin {
  static final _logger = Logger("SpectrumVisualizer");

  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();

  final _repaint = ValueNotifier<int>(0);

  late final Ticker _ticker;

  /// This visualizer's registration with [SpectrumHub]; a fresh token per attach, so a late release from a superseded
  /// attach can never drop a newer one.
  Object? _hubToken;
  int? _sessionId;
  int _attachGeneration = 0;
  StreamSubscription<int?>? _sessionSubscription;
  StreamSubscription<SpectrumFrame>? _frameSubscription;

  SpectrumFrame? _pending;
  Duration _pendingAt = Duration.zero;
  static const _staleAfter = Duration(milliseconds: 300);

  final _bars = SpectrumBars();
  Float32List _incoming = Float32List(0);

  Duration _lastFrame = Duration.zero;
  Duration _elapsed = Duration.zero;
  bool _receiving = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _sessionSubscription = _audioHandler.androidAudioSessionIdStream.distinct().listen(_attach);
    } else {
      _attach(null);
    }
    // The ticker only runs while frames are coming in (or the bars are still falling back to rest); a ticker
    // left running schedules a frame on every vsync, which keeps the whole app rendering for nothing.
    _ticker = createTicker(_onTick);
  }

  void _wakeTicker() {
    if (mounted && _receiving && !_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _sessionSubscription?.cancel();
    _detach();
    _repaint.dispose();
    super.dispose();
  }

  Future<void> _attach(int? sessionId) async {
    _sessionId = sessionId;
    final generation = ++_attachGeneration;
    await _detach();
    final settings = FinampSettingsHelper.finampSettings;
    if (!settings.visualizerEnabled) return;
    // Nothing to draw here in this style (e.g. the radial one is drawn around the cover): don't run a source for it.
    if (SpectrumVisualizer.effectiveStyle(settings.visualizerStyle, widget.placement) == null) return;

    final token = Object();
    _hubToken = token;
    final flowing = await SpectrumHub.instance.acquire(
      token,
      androidSessionId: sessionId,
      fps: FinampSettingsHelper.finampSettings.visualizerFps,
    );
    if (!mounted || generation != _attachGeneration) {
      // A newer attach (or dispose) took over and already released this token.
      return;
    }
    if (!flowing) {
      _logger.info("No spectrum source available; visualizer stays hidden");
      return;
    }

    _frameSubscription = SpectrumHub.instance.frames.listen((frame) {
      _pending = frame;
      _pendingAt = _ticker.isActive ? _elapsed : Duration.zero;
      _wakeTicker();
    });
    setState(() => _receiving = true);
    _wakeTicker();
  }

  Future<void> _detach() async {
    await _frameSubscription?.cancel();
    _frameSubscription = null;
    final token = _hubToken;
    _hubToken = null;
    if (token != null) await SpectrumHub.instance.release(token);
    _pending = null;
    if (_ticker.isActive) _ticker.stop();
    if (mounted && _receiving) setState(() => _receiving = false);
  }

  /// Highest level seen recently, decaying slowly: what auto gain rescales to.
  double _gainPeak = 0.3;

  /// Applies the style's reactivity options to the freshly binned spectrum: tilt, auto gain, contrast.
  void _shapeIncoming(VisualizerStyleTune tune, int bands) {
    final tilt = tune.tilt;
    final contrast = tune.contrast;
    var peak = 0.0;
    for (var i = 0; i < bands; i++) {
      var v = _incoming[i];
      if (tilt != 0) {
        // +1 doubles the highest band and halves the lowest; -1 does the opposite.
        final position = bands <= 1 ? 0.5 : i / (bands - 1);
        v *= pow(2, tilt * (position * 2 - 1)).toDouble();
      }
      _incoming[i] = v;
      if (v > peak) peak = v;
    }
    if (tune.autoGain) {
      _gainPeak = max(peak, _gainPeak * 0.995);
      final gain = (0.8 / max(_gainPeak, 0.15)).clamp(0.6, 4.0);
      for (var i = 0; i < bands; i++) {
        _incoming[i] = _incoming[i] * gain;
      }
    }
    if (contrast != 1) {
      for (var i = 0; i < bands; i++) {
        _incoming[i] = pow(_incoming[i].clamp(0.0, 1.0), contrast).toDouble();
      }
    }
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    if (!_receiving) {
      _ticker.stop();
      return;
    }

    final settings = FinampSettingsHelper.finampSettings;
    final frameDuration = Duration(microseconds: (1000000 / settings.visualizerFps.clamp(1, 120)).round());
    if (elapsed - _lastFrame < frameDuration) return;
    final dt = _lastFrame == Duration.zero ? 1 / settings.visualizerFps : (elapsed - _lastFrame).inMicroseconds / 1e6;
    _lastFrame = elapsed;
    _bars.advance(dt.clamp(0.0, 0.2));

    final bands = settings.visualizerBins;
    final bars = _bars.values;
    if (bars.length != bands) {
      _bars.values = Float32List(bands);
      _incoming = Float32List(bands);
      return;
    }

    final tune = VisualizerStyleTune.of(
      settings.visualizerStyleTuning,
      SpectrumVisualizer.effectiveStyle(settings.visualizerStyle, widget.placement) ?? settings.visualizerStyle,
    );
    final smoothing = (tune.smoothing ?? settings.visualizerSmoothing).clamp(0.0, 0.99);
    final stale = elapsed - _pendingAt > _staleAfter;
    final frame = stale ? null : _pending;

    if (frame == null) {
      var peak = 0.0;
      for (var i = 0; i < bands; i++) {
        bars[i] *= 0.97;
        if (bars[i] > peak) peak = bars[i];
      }
      if (peak < 0.002) {
        // Nothing left to draw (paused, or the source went quiet): sleep until the next frame arrives.
        bars.fillRange(0, bands, 0);
        _pending = null;
        _repaint.value++;
        _ticker.stop();
        return;
      }
    } else {
      binFrame(
        frame,
        _incoming,
        minHz: settings.visualizerMinHz,
        maxHz: settings.visualizerMaxHz,
        dbFloor: settings.visualizerDbFloor,
        dbCeiling: settings.visualizerDbCeiling,
        logScale: settings.visualizerLogScale,
      );
      _shapeIncoming(tune, bands);
      final attack = (tune.attack ?? 1 - smoothing).clamp(0.01, 1.0);
      final release = (tune.release ?? smoothing * 0.25).clamp(0.01, 1.0);
      for (var i = 0; i < bands; i++) {
        final alpha = _incoming[i] > bars[i] ? attack : release;
        bars[i] = bars[i] * (1 - alpha) + _incoming[i] * alpha;
      }
    }

    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(finampSettingsProvider.visualizerEnabled, (_, _) => _attach(_sessionId));
    ref.listen(finampSettingsProvider.visualizerFps, (_, _) => _attach(_sessionId));
    ref.listen(finampSettingsProvider.visualizerStyle, (_, _) => _attach(_sessionId));

    final settings = ref.watch(finampSettingsProvider).value;
    final style = settings == null
        ? null
        : SpectrumVisualizer.effectiveStyle(settings.visualizerStyle, widget.placement);
    if (settings == null || style == null || !settings.visualizerEnabled || !_receiving) {
      return const SizedBox.shrink();
    }

    final tune = VisualizerStyleTune.of(settings.visualizerStyleTuning, style);
    final painter = SpectrumPainter(
      bars: _bars,
      repaint: _repaint,
      style: style,
      accent: Theme.of(context).colorScheme.primary,
      scale: tune.scale ?? settings.visualizerScale,
      bottomOpacity: tune.bottomOpacity ?? settings.visualizerBottomOpacity,
      topOpacity: tune.topOpacity ?? settings.visualizerTopOpacity,
      useSplines: tune.useSplines ?? settings.visualizerUseSplines,
      strokeWidth: tune.strokeWidth ?? settings.visualizerStrokeWidth,
      fillEnabled: tune.fillEnabled ?? settings.visualizerFillEnabled,
      tune: tune,
      radialInner: widget.placement == SpectrumPlacement.aroundCover ? SpectrumCoverRing.innerFraction : 0.45,
    );

    // The radial style fills its whole box; the others sit along the bottom.
    if (style == VisualizerStyle.radial) {
      return IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(size: Size.infinite, painter: painter),
        ),
      );
    }

    return IgnorePointer(
      child: FractionallySizedBox(
        alignment: Alignment.bottomCenter,
        heightFactor: (tune.heightFactor ?? settings.visualizerHeightFactor).clamp(0.05, 1.0),
        child: RepaintBoundary(
          child: CustomPaint(size: Size.infinite, painter: painter),
        ),
      ),
    );
  }
}

/// Puts the radial spectrum around a square [child] (the cover), spilling [padding] of its size outside it on each side.
class SpectrumCoverRing extends StatelessWidget {
  const SpectrumCoverRing({super.key, required this.child});

  final Widget child;

  static const padding = 0.18;

  /// The cover's edge as a fraction of the ring box's half-size.
  static const innerFraction = 1 / (1 + 2 * padding);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final spill = side.isFinite ? side * padding : 0.0;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Positioned(
              left: -spill,
              right: -spill,
              top: -spill,
              bottom: -spill,
              child: const SpectrumVisualizer(placement: SpectrumPlacement.aroundCover),
            ),
            child,
          ],
        );
      },
    );
  }
}
