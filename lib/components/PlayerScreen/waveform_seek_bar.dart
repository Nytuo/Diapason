import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/waveform_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// Loads the waveform peaks of [item] and hands them to [builder]: null until they are known (or when they can't be
/// computed, e.g. a stream that isn't cached yet), so the caller can show its usual slider meanwhile.
///
/// A streamed track gets another try once the player has buffered all of it, when the stream cache holds the file.
class WaveformPeaksBuilder extends StatefulWidget {
  const WaveformPeaksBuilder({super.key, required this.item, required this.builder});

  final MediaItem? item;
  final Widget Function(BuildContext context, Float32List? peaks) builder;

  @override
  State<WaveformPeaksBuilder> createState() => _WaveformPeaksBuilderState();
}

class _WaveformPeaksBuilderState extends State<WaveformPeaksBuilder> {
  Float32List? _peaks;
  String? _loadingFor;
  int _retries = 0;
  StreamSubscription<PlaybackState>? _bufferSubscription;
  Timer? _retryTimer;

  static const _maxRetries = 6;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WaveformPeaksBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_keyOf(oldWidget.item) != _keyOf(widget.item)) {
      _retries = 0;
      _load();
    }
  }

  @override
  void dispose() {
    _bufferSubscription?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  static String? _keyOf(MediaItem? item) =>
      item == null ? null : "${WaveformService.trackIdOf(item)}-${item.duration?.inSeconds}";

  void _load({bool retry = false}) {
    _bufferSubscription?.cancel();
    _bufferSubscription = null;
    _retryTimer?.cancel();
    final item = widget.item;
    final key = _keyOf(item);
    _loadingFor = key;
    if (item == null) {
      _peaks = null;
      return;
    }
    final service = WaveformService.instance;
    _peaks = service.cached(item);
    if (_peaks != null) return;
    unawaited(
      service
          .peaksFor(item, retry: retry)
          .then((peaks) {
            if (!mounted || _loadingFor != key) return;
            if (peaks != null) {
              setState(() => _peaks = peaks);
            } else {
              _retryLater(item, key);
            }
          })
          .catchError((Object _) {
            if (mounted && _loadingFor == key) _retryLater(item, key);
          }),
    );
  }

  /// No peaks yet (no local file, the player still switching tracks, a cache file still being written): try again on
  /// a growing delay, and as soon as the whole stream is buffered. Without this a miss at the moment of a track change
  /// left the plain slider until the setting was toggled.
  void _retryLater(MediaItem item, String? key) {
    if (_retries >= _maxRetries) return;
    _retryTimer?.cancel();
    final delay = Duration(milliseconds: 800 * (1 << _retries));
    _retries++;
    _retryTimer = Timer(delay, () {
      if (mounted && _loadingFor == key && _peaks == null) _load(retry: true);
    });
    _waitForFullBuffer(item, key);
  }

  /// Retries as soon as the whole stream has been buffered (the cache file is then complete).
  void _waitForFullBuffer(MediaItem item, String? key) {
    final duration = item.duration;
    if (_bufferSubscription != null || duration == null || !GetIt.instance.isRegistered<MusicPlayerBackgroundTask>()) {
      return;
    }
    final handler = GetIt.instance<MusicPlayerBackgroundTask>();
    _bufferSubscription = handler.playbackState.listen((state) {
      if (state.bufferedPosition < duration - const Duration(seconds: 1)) return;
      _bufferSubscription?.cancel();
      _bufferSubscription = null;
      // Leave the cache a moment to rename its partial file.
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _loadingFor == key && _peaks == null) _load(retry: true);
      });
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _peaks);
}

/// A seek bar drawn as the waveform of the track: tap or drag to seek. Values are fractions of the track (0..1).
class WaveformSeekBar extends StatefulWidget {
  const WaveformSeekBar({
    super.key,
    required this.peaks,
    required this.value,
    required this.activeColor,
    required this.inactiveColor,
    this.onChanged,
    this.onChangeEnd,
    this.height = 36,
    this.semanticLabel,
  });

  final Float32List peaks;
  final double value;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double height;
  final String? semanticLabel;

  @override
  State<WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<WaveformSeekBar> {
  final _cache = _WaveformPathCache();
  double? _dragging;

  double _fractionAt(Offset local, double width) => width <= 0 ? 0 : (local.dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null || widget.onChangeEnd != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void update(Offset local) {
          final v = _fractionAt(local, width);
          _dragging = v;
          widget.onChanged?.call(v);
        }

        void end() {
          final v = _dragging;
          _dragging = null;
          if (v != null) widget.onChangeEnd?.call(v);
        }

        final bar = RepaintBoundary(
          child: CustomPaint(
            size: Size(width, widget.height),
            painter: _WaveformPainter(
              peaks: widget.peaks,
              value: widget.value.clamp(0.0, 1.0),
              active: widget.activeColor,
              inactive: widget.inactiveColor,
              cache: _cache,
            ),
          ),
        );
        return Semantics(
          slider: true,
          label: widget.semanticLabel,
          value: "${(widget.value.clamp(0.0, 1.0) * 100).round()}%",
          child: !enabled
              ? bar
              : MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => update(d.localPosition),
                    onTapUp: (_) => end(),
                    onTapCancel: () => _dragging = null,
                    onHorizontalDragStart: (d) => update(d.localPosition),
                    onHorizontalDragUpdate: (d) => update(d.localPosition),
                    onHorizontalDragEnd: (_) => end(),
                    onHorizontalDragCancel: end,
                    child: bar,
                  ),
                ),
        );
      },
    );
  }
}

/// The bars only change with the peaks or the size, so their path is built once and reused for every position tick.
class _WaveformPathCache {
  Float32List? peaks;
  Size? size;
  Path? path;
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.value,
    required this.active,
    required this.inactive,
    required this.cache,
  });

  final Float32List peaks;
  final double value;
  final Color active;
  final Color inactive;
  final _WaveformPathCache cache;

  static const _barWidth = 2.0;
  static const _gap = 1.5;
  static const _minHeight = 2.0;

  Path _path(Size size) {
    if (cache.path != null && identical(cache.peaks, peaks) && cache.size == size) return cache.path!;
    final count = max(1, ((size.width + _gap) / (_barWidth + _gap)).floor());
    final step = count == 1 ? 0.0 : (size.width - _barWidth) / (count - 1);
    final path = Path();
    final mid = size.height / 2;
    for (var i = 0; i < count; i++) {
      final from = (i * peaks.length / count).floor();
      final to = max(from + 1, ((i + 1) * peaks.length / count).floor()).clamp(0, peaks.length);
      var v = 0.0;
      for (var j = from; j < to; j++) {
        if (peaks[j] > v) v = peaks[j];
      }
      // A slight curve so quiet passages stay visible.
      final h = max(_minHeight, pow(v, 0.8) * size.height);
      path.addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * step, mid - h / 2, _barWidth, h),
          const Radius.circular(_barWidth / 2),
        ),
      );
    }
    cache
      ..peaks = peaks
      ..size = size
      ..path = path;
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || peaks.isEmpty) return;
    final path = _path(size);
    final split = size.width * value;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(split, 0, size.width, size.height));
    canvas.drawPath(path, Paint()..color = inactive);
    canvas.restore();
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, split, size.height));
    canvas.drawPath(path, Paint()..color = active);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.value != value || !identical(old.peaks, peaks) || old.active != active || old.inactive != inactive;
}
