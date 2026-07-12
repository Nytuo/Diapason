import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/spectrum_binner.dart';
import 'package:diapason/services/spectrum_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// The spectrum curve drawn along the bottom of the player screen, behind the
/// controls.

class SpectrumVisualizer extends ConsumerStatefulWidget {
  const SpectrumVisualizer({super.key});

  @override
  ConsumerState<SpectrumVisualizer> createState() => _SpectrumVisualizerState();
}

class _SpectrumVisualizerState extends ConsumerState<SpectrumVisualizer> with SingleTickerProviderStateMixin {
  static final _logger = Logger("SpectrumVisualizer");

  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();

  final _repaint = ValueNotifier<int>(0);

  late final Ticker _ticker;

  SpectrumSource? _source;
  int? _sessionId;
  StreamSubscription<int?>? _sessionSubscription;
  StreamSubscription<SpectrumFrame>? _frameSubscription;

  SpectrumFrame? _pending;
  Duration _pendingAt = Duration.zero;
  static const _staleAfter = Duration(milliseconds: 300);

  Float32List _bars = Float32List(0);
  final _bars = _SpectrumBars();
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
    _ticker = createTicker(_onTick)..start();
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
    await _detach();
    if (!FinampSettingsHelper.finampSettings.visualizerEnabled) return;

    final source = createSpectrumSource(
      androidSessionId: sessionId,
      fps: FinampSettingsHelper.finampSettings.visualizerFps,
    );
    if (source == null) return;

    if (!await source.start()) {
      _logger.info("No spectrum source available; visualizer stays hidden");
      return;
    }
    if (!mounted) {
      await source.stop();
      return;
    }

    _source = source;
    _frameSubscription = source.frames.listen((frame) {
      _pending = frame;
      _pendingAt = _elapsed;
    });
    setState(() => _receiving = true);
  }

  Future<void> _detach() async {
    await _frameSubscription?.cancel();
    _frameSubscription = null;
    await _source?.stop();
    _source = null;
    _pending = null;
    if (mounted && _receiving) setState(() => _receiving = false);
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    if (!_receiving) return;

    final settings = FinampSettingsHelper.finampSettings;
    final frameDuration = Duration(microseconds: (1000000 / settings.visualizerFps.clamp(1, 120)).round());
    if (elapsed - _lastFrame < frameDuration) return;
    _lastFrame = elapsed;

    final bands = settings.visualizerBins;
    final bars = _bars.values;
    if (bars.length != bands) {
      _bars.values = Float32List(bands);
      _incoming = Float32List(bands);
      return;
    }

    final smoothing = settings.visualizerSmoothing.clamp(0.0, 0.99);
    final stale = elapsed - _pendingAt > _staleAfter;
    final frame = stale ? null : _pending;

    if (frame == null) {
      for (var i = 0; i < bands; i++) {
        bars[i] *= 0.97;
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
      final attack = 1 - smoothing;
      final decay = (1 - smoothing * 0.25);
      for (var i = 0; i < bands; i++) {
        final alpha = _incoming[i] > bars[i] ? attack : 1 - decay;
        bars[i] = bars[i] * (1 - alpha) + _incoming[i] * alpha;
      }
    }

    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(finampSettingsProvider.visualizerEnabled, (_, _) => _attach(_sessionId));
    ref.listen(finampSettingsProvider.visualizerFps, (_, _) => _attach(_sessionId));

    final settings = ref.watch(finampSettingsProvider).valueOrNull;
    if (settings == null || !settings.visualizerEnabled || !_receiving) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      child: FractionallySizedBox(
        alignment: Alignment.bottomCenter,
        heightFactor: settings.visualizerHeightFactor.clamp(0.05, 1.0),
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _SpectrumPainter(
              bars: _bars,
              repaint: _repaint,
              accent: Theme.of(context).colorScheme.primary,
              scale: settings.visualizerScale,
              bottomOpacity: settings.visualizerBottomOpacity,
              topOpacity: settings.visualizerTopOpacity,
              useSplines: settings.visualizerUseSplines,
              strokeWidth: settings.visualizerStrokeWidth,
              fillEnabled: settings.visualizerFillEnabled,
            ),
          ),
        ),
      ),
    );
  }
}

class _SpectrumBars {
  Float32List values = Float32List(0);
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.bars,
    required Listenable repaint,
    required this.accent,
    required this.scale,
    required this.bottomOpacity,
    required this.topOpacity,
    required this.useSplines,
    required this.strokeWidth,
    required this.fillEnabled,
  }) : super(repaint: repaint);

  final _SpectrumBars bars;
  final Color accent;
  final double scale;
  final double bottomOpacity;
  final double topOpacity;
  final bool useSplines;
  final double strokeWidth;
  final bool fillEnabled;

  static const _segments = 6;

  static const _headroom = 0.85;

  @override
  void paint(Canvas canvas, Size size) {
    final values = bars.values;
    final n = values.length;
    if (n < 2 || size.width <= 0 || size.height <= 0) return;

    var maxBar = 0.0;
    for (var i = 0; i < n; i++) {
      if (values[i] > maxBar) maxBar = values[i];
    }
    if (maxBar < 0.002) return;

    final points = List<Offset>.generate(n, (i) {
      final magnitude = min(values[i] * scale, 1.0);
      return Offset(i / (n - 1) * size.width, size.height - magnitude * size.height * _headroom);
    }, growable: false);

    final curve = useSplines ? _catmullRom(points) : points;

    final path = Path()..moveTo(curve.first.dx, curve.first.dy);
    for (var i = 1; i < curve.length; i++) {
      path.lineTo(curve[i].dx, curve[i].dy);
    }

    if (fillEnabled) {
      final fillPath = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              accent.withValues(alpha: topOpacity),
              accent.withValues(alpha: bottomOpacity),
            ],
          ).createShader(Offset.zero & size),
      );
    }

    if (strokeWidth > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = accent.withValues(alpha: min(bottomOpacity + 0.15, 1.0)),
      );
    }
  }

  List<Offset> _catmullRom(List<Offset> points) {
    final out = <Offset>[];
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[max(i - 1, 0)];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = points[min(i + 2, points.length - 1)];
      for (var s = 0; s < _segments; s++) {
        final t = s / _segments;
        final t2 = t * t;
        final t3 = t2 * t;
        out.add(
          Offset(
            0.5 *
                (2 * p1.dx +
                    (-p0.dx + p2.dx) * t +
                    (2 * p0.dx - 5 * p1.dx + 4 * p2.dx - p3.dx) * t2 +
                    (-p0.dx + 3 * p1.dx - 3 * p2.dx + p3.dx) * t3),
            0.5 *
                (2 * p1.dy +
                    (-p0.dy + p2.dy) * t +
                    (2 * p0.dy - 5 * p1.dy + 4 * p2.dy - p3.dy) * t2 +
                    (-p0.dy + 3 * p1.dy - 3 * p2.dy + p3.dy) * t3),
          ),
        );
      }
    }
    out.add(points.last);
    return out;
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) =>
      accent != oldDelegate.accent ||
      scale != oldDelegate.scale ||
      bottomOpacity != oldDelegate.bottomOpacity ||
      topOpacity != oldDelegate.topOpacity ||
      useSplines != oldDelegate.useSplines ||
      strokeWidth != oldDelegate.strokeWidth ||
      fillEnabled != oldDelegate.fillEnabled;
}
