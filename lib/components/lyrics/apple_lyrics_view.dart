import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:diapason/components/lyrics/lyric_text.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lyrics_extras.dart';
import 'package:diapason/services/progress_state_stream.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// One row of the animated view: a lyric line, or the dots shown through a long instrumental gap.
@immutable
class LyricsDisplayItem {
  const LyricsDisplayItem.line(int this.lineIndex, this.startMicros, this.endMicros);

  const LyricsDisplayItem.interlude(this.startMicros, this.endMicros) : lineIndex = null;

  final int? lineIndex;
  final int startMicros;

  /// When the line is done (its last word, or the next line), or when the gap ends.
  final int endMicros;

  bool get isInterlude => lineIndex == null;

  /// Gaps at least this long get dots.
  static const interludeMicros = 4000000;

  /// Rows for synced [lines]: blank lines are dropped, and long gaps (the intro, a blank line, or the silence after a
  /// word-timed line) become interludes.
  static List<LyricsDisplayItem> build(List<LyricLine> lines) {
    final items = <LyricsDisplayItem>[];
    int? nextStartAfter(int i) {
      for (var j = i + 1; j < lines.length; j++) {
        if (lines[j].start != null) return lines[j].startMicros;
      }
      return null;
    }

    final firstText = lines.indexWhere((l) => l.start != null && (l.text ?? "").trim().isNotEmpty);
    if (firstText >= 0 && lines[firstText].startMicros >= interludeMicros) {
      items.add(LyricsDisplayItem.interlude(0, lines[firstText].startMicros));
    }
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.start == null) continue;
      final start = line.startMicros;
      final next = nextStartAfter(i);
      if ((line.text ?? "").trim().isEmpty) {
        if (i > firstText && next != null && next - start >= interludeMicros) {
          items.add(LyricsDisplayItem.interlude(start, next));
        }
        continue;
      }
      final wordsEnd = line.cues?.map((c) => c.endMicros ?? c.startMicros).fold<int?>(null, (a, b) => max(a ?? b, b));
      final end = wordsEnd ?? next ?? start + 5000000;
      items.add(LyricsDisplayItem.line(i, start, next == null ? end : min(max(end, start), next)));
      if (wordsEnd != null && next != null && next - wordsEnd >= interludeMicros) {
        // A blank line right after already makes the interlude.
        final blankFollows = i + 1 < lines.length && (lines[i + 1].text ?? "").trim().isEmpty;
        if (!blankFollows) items.add(LyricsDisplayItem.interlude(wordsEnd, next));
      }
    }
    return items;
  }

  /// The row playing at [micros], or -1 before the first.
  static int activeAt(List<LyricsDisplayItem> items, int micros) {
    var active = -1;
    for (var i = 0; i < items.length; i++) {
      if (items[i].startMicros > micros) break;
      active = i;
    }
    // An interlude is over once the next line starts; past its end and before anything else, keep it shown.
    return active;
  }
}

/// A damped spring for one row's vertical offset, released after [delay] seconds (the stagger).
class _Spring {
  _Spring(this.value) : target = value;

  double value;
  double target;
  double velocity = 0;
  double delay = 0;

  static const stiffness = 170.0;
  static const damping = 23.0;

  bool get settled => delay <= 0 && (value - target).abs() < 0.3 && velocity.abs() < 2;

  void step(double dt) {
    if (delay > 0) {
      delay -= dt;
      if (delay > 0) return;
    }
    final a = -stiffness * (value - target) - damping * velocity;
    velocity += a * dt;
    value += velocity * dt;
    if (settled) {
      value = target;
      velocity = 0;
    }
  }

  void jump(double to) {
    value = to;
    target = to;
    velocity = 0;
    delay = 0;
  }
}

/// Apple Music-like synced lyrics: the active line springs to an anchor near the top, upcoming lines follow one after
/// the other, the active line is full size and opacity while the others are smaller, dimmer and blurred with distance;
/// words light up with a soft gradient sweep, and long gaps show breathing dots. Tap a line to play from it.
///
/// Rows are laid out once and moved by a [Flow] at paint time, so the per-frame work is the transforms and the active
/// line's own repaint, never a rebuild of the list.
class AppleLyricsView extends StatefulWidget {
  const AppleLyricsView({
    super.key,
    required this.lines,
    required this.extras,
    required this.style,
    required this.textAlign,
    required this.offsetMicros,
    required this.onSeek,
    this.autoScrollEnabled = true,
    this.onUserScroll,
    this.padding = EdgeInsets.zero,
    @visibleForTesting this.progress,
  });

  /// Playback to follow; the player's own by default.
  final Stream<ProgressState>? progress;

  final List<LyricLine> lines;
  final LyricsExtras extras;
  final TextStyle style;
  final TextAlign textAlign;

  /// The track's lyrics offset, in microseconds (positive: lyrics later).
  final int Function() offsetMicros;

  /// Plays from a line (its time in the lyrics' timeline).
  final void Function(LyricLine line) onSeek;

  /// Follows the playing line. Turned off by scrolling, until the parent turns it back on.
  final bool autoScrollEnabled;
  final VoidCallback? onUserScroll;
  final EdgeInsets padding;

  @override
  State<AppleLyricsView> createState() => _AppleLyricsViewState();
}

class _AppleLyricsViewState extends State<AppleLyricsView> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late List<LyricsDisplayItem> _items;
  int _active = -1;

  /// Repaints the flow (row positions, scale, opacity).
  final _frame = _Frame();

  /// The active line's sweep.
  final _fill = ValueNotifier<LyricFill>(LyricFill.none);

  /// The active interlude's progress (0–1) and the time, for its breathing.
  final _interlude = ValueNotifier<(double, double)>((0, 0));

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  StreamSubscription<ProgressState>? _progress;

  // Playback position, extrapolated between position updates.
  int _basePositionMicros = 0;
  final _sinceBase = Stopwatch();
  bool _playing = false;
  double _speed = 1;

  // Layout: row heights from the last paint, and the springs moving them.
  List<double> _heights = const [];
  List<_Spring> _springs = [];
  final List<double> _emphasis = [];
  double _viewport = 0;
  double _scroll = 0; // the offset every spring heads to
  bool _userScrolling = false;
  double _flingVelocity = 0;
  bool _visible = true;

  static const _gap = 12.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _items = LyricsDisplayItem.build(widget.lines);
    _resetRows();
    _ticker = createTicker(_onTick);
    if (widget.progress != null) {
      _progress = widget.progress!.listen(_onProgress);
    } else {
      final state = progressState;
      if (state != null) _onProgress(state);
      _progress = progressStateStream.listen(_onProgress);
    }
  }

  void _resetRows() {
    _springs = [for (final _ in _items) _Spring(_scroll)];
    _emphasis
      ..clear()
      ..addAll(List.filled(_items.length, 0.0));
  }

  @override
  void didUpdateWidget(covariant AppleLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _items = LyricsDisplayItem.build(widget.lines);
      _active = -1;
      _heights = const [];
      _scroll = 0;
      _resetRows();
      _fill.value = LyricFill.none;
    }
    if (widget.autoScrollEnabled && !oldWidget.autoScrollEnabled) {
      _userScrolling = false;
      _flingVelocity = 0;
      _retarget(stagger: false);
    }
    _wake();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    _wake();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progress?.cancel();
    _ticker.dispose();
    _frame.dispose();
    _fill.dispose();
    _interlude.dispose();
    super.dispose();
  }

  void _onProgress(ProgressState state) {
    _basePositionMicros = state.position.inMicroseconds;
    _sinceBase
      ..reset()
      ..start();
    _playing = state.playbackState.playing && state.playbackState.processingState == AudioProcessingState.ready;
    _speed = state.playbackState.speed <= 0 ? 1 : state.playbackState.speed;
    _update();
    _wake();
  }

  int get _micros {
    var position = _basePositionMicros;
    if (_playing) {
      // Never run more than a second past the last report (a stall would otherwise race ahead).
      position += min(_sinceBase.elapsedMicroseconds * _speed, 1000000).round();
    }
    return position - widget.offsetMicros();
  }

  /// Read in build: no springs, sweeps or blur when the system asks for less motion.
  bool _reduceMotion = false;

  /// Keeps ticking while something moves; stops once still and paused.
  void _wake() {
    if (!mounted) return;
    final needed = _visible && (_playing || _moving || _flingVelocity != 0);
    if (needed && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!needed && _ticker.isActive) {
      _ticker.stop();
    }
  }

  bool get _moving {
    if (_springs.any((s) => !s.settled)) return true;
    for (var i = 0; i < _emphasis.length; i++) {
      if ((_emphasis[i] - (i == _active ? 1 : 0)).abs() > 0.01) return true;
    }
    return false;
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero ? 1 / 60 : min((elapsed - _lastTick).inMicroseconds / 1e6, 1 / 20);
    _lastTick = elapsed;
    _update();

    if (_flingVelocity != 0) {
      _scrollBy(_flingVelocity * dt);
      _flingVelocity *= exp(-dt * 4.5);
      if (_flingVelocity.abs() < 20) _flingVelocity = 0;
    }
    final instant = _reduceMotion;
    for (final spring in _springs) {
      instant ? spring.jump(spring.target) : spring.step(dt);
    }
    final k = instant ? 1.0 : 1 - exp(-dt * 10);
    for (var i = 0; i < _emphasis.length; i++) {
      _emphasis[i] += ((i == _active ? 1.0 : 0.0) - _emphasis[i]) * k;
    }
    _frame.tick();
    _wake();
  }

  /// Follows the playing position: active row, the sweep, interlude progress.
  void _update() {
    if (!mounted) return;
    final micros = _micros;
    final active = LyricsDisplayItem.activeAt(_items, micros);
    if (active != _active) {
      final previous = _active;
      setState(() => _active = active);
      _retarget(stagger: previous >= 0 && (active - previous).abs() == 1);
    }
    if (active < 0) {
      _fill.value = LyricFill.none;
      return;
    }
    final item = _items[active];
    if (item.isInterlude) {
      final length = max(1, item.endMicros - item.startMicros);
      _interlude.value = (((micros - item.startMicros) / length).clamp(0.0, 1.0), micros / 1e6);
    } else {
      _fill.value = LyricFill.at(widget.lines[item.lineIndex!], micros, lineEndMicros: item.endMicros);
    }
  }

  /// Where rows are when [_active] sits at the anchor.
  double get _anchor => _viewport * 0.3;

  double _top(int index) {
    var y = 0.0;
    for (var i = 0; i < index && i < _heights.length; i++) {
      y += _heights[i] + _gap;
    }
    return y;
  }

  double get _contentHeight => _top(_heights.length);

  void _retarget({bool stagger = true}) {
    if (_heights.length != _items.length || _userScrolling || !widget.autoScrollEnabled) return;
    final focus = max(_active, 0);
    _scroll = _anchor - _top(focus);
    for (var i = 0; i < _springs.length; i++) {
      final spring = _springs[i];
      spring.target = _scroll;
      // Rows from the active one down set off one after the other, like a wave.
      spring.delay = stagger && !_reduceMotion ? (i - focus + 1).clamp(0, 8) * 0.045 : 0;
    }
    _wake();
  }

  void _scrollBy(double delta) {
    final minScroll = _anchor - _contentHeight;
    final maxScroll = _anchor;
    _scroll = (_scroll + delta).clamp(min(minScroll, maxScroll), maxScroll);
    for (final spring in _springs) {
      spring.jump(_scroll);
    }
    _frame.tick();
  }

  void _startUserScroll() {
    if (!_userScrolling) {
      _userScrolling = true;
      widget.onUserScroll?.call();
      setState(() {}); // unblur
    }
  }

  /// Called by the flow after layout: picks up row heights, and puts rows in place the first time.
  void _onLayout(List<double> heights, double viewport) {
    final first = _heights.isEmpty;
    final changed = !listEquals(heights, _heights) || viewport != _viewport;
    if (!changed) return;
    _heights = heights;
    _viewport = viewport;
    // After this frame: changing targets during paint is fine, but the ticker must be started outside it.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (first && !_userScrolling) {
        _scroll = _anchor - _top(max(_active, 0));
        for (final s in _springs) {
          s.jump(_scroll);
        }
        _frame.tick();
      } else {
        _retarget(stagger: false);
      }
    });
  }

  double _dimOpacity(int distance) => switch (distance) {
    0 => 1,
    1 => 0.42,
    2 => 0.34,
    _ => 0.28,
  };

  @override
  Widget build(BuildContext context) {
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final color = widget.style.color ?? Colors.white;
    final blur = !_userScrolling && widget.autoScrollEnabled && !_reduceMotion;
    final secondary = widget.style.copyWith(
      fontSize: (widget.style.fontSize ?? 24) * 0.6,
      fontWeight: FontWeight.w500,
      height: 1.25,
      color: color.withValues(alpha: 0.85),
    );

    final children = <Widget>[
      for (var i = 0; i < _items.length; i++)
        _row(i, color: color, secondary: secondary, blurSigma: blur ? min((i - _active).abs(), 5) * 0.9 : 0.0),
    ];

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _startUserScroll();
          _flingVelocity = 0;
          _scrollBy(-event.scrollDelta.dy);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) {
          _flingVelocity = 0;
          _startUserScroll();
        },
        onVerticalDragUpdate: (details) => _scrollBy(details.delta.dy),
        onVerticalDragEnd: (details) {
          _flingVelocity = details.velocity.pixelsPerSecond.dy;
          _wake();
        },
        child: ClipRect(
          child: Padding(
            padding: widget.padding,
            child: Flow(delegate: _LyricsFlowDelegate(this), children: children),
          ),
        ),
      ),
    );
  }

  Widget _row(int index, {required Color color, required TextStyle secondary, required double blurSigma}) {
    final item = _items[index];
    final active = index == _active;
    Widget child;
    if (item.isInterlude) {
      child = active
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _InterludeDots(progress: _interlude, color: color, textAlign: widget.textAlign),
            )
          : const SizedBox(height: 0);
    } else {
      final line = widget.lines[item.lineIndex!];
      final extras = widget.extras[item.lineIndex!];
      final crossAxis = switch (widget.textAlign) {
        TextAlign.center => CrossAxisAlignment.center,
        TextAlign.end || TextAlign.right => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.start,
      };
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          widget.onSeek(line);
          if (_userScrolling) {
            _userScrolling = false;
            _flingVelocity = 0;
            setState(() {});
          }
          _retarget(stagger: false);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: crossAxis,
            mainAxisSize: MainAxisSize.min,
            children: [
              LyricText(
                text: line.text ?? "",
                style: widget.style,
                textAlign: widget.textAlign,
                ruby: extras.ruby,
                // The active line: unsung words faint, sung ones bright. Others are drawn bright and dimmed as a whole.
                color: active ? color.withValues(alpha: 0.36) : color,
                fillColor: active ? color : null,
                fill: active ? _fill : null,
              ),
              if (extras.romaji != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(extras.romaji!, style: secondary, textAlign: widget.textAlign),
                ),
              if (extras.translation != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    extras.translation!,
                    style: secondary.copyWith(fontStyle: FontStyle.italic),
                    textAlign: widget.textAlign,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return RepaintBoundary(
      key: ValueKey(index),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: blurSigma),
        duration: const Duration(milliseconds: 350),
        child: child,
        builder: (context, sigma, child) => sigma < 0.05
            ? child!
            : ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: child,
              ),
      ),
    );
  }
}

class _Frame extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _LyricsFlowDelegate extends FlowDelegate {
  _LyricsFlowDelegate(this.state) : super(repaint: state._frame);

  final _AppleLyricsViewState state;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints(maxWidth: constraints.maxWidth);

  @override
  void paintChildren(FlowPaintingContext context) {
    final count = context.childCount;
    final heights = [for (var i = 0; i < count; i++) context.getChildSize(i)!.height];
    state._onLayout(heights, context.size.height);
    final width = context.size.width;
    final viewport = context.size.height;
    final align = switch (state.widget.textAlign) {
      TextAlign.center => 0.5,
      TextAlign.end || TextAlign.right => 1.0,
      _ => 0.0,
    };
    var top = 0.0;
    for (var i = 0; i < count; i++) {
      final size = context.getChildSize(i)!;
      final spring = i < state._springs.length ? state._springs[i].value : 0.0;
      final y = top + spring;
      top += size.height + _AppleLyricsViewState._gap;
      if (size.height == 0 || y + size.height < -40 || y > viewport + 40) continue;
      final emphasis = i < state._emphasis.length ? state._emphasis[i] : 0.0;
      final distance = state._active < 0 ? 3 : (i - state._active).abs();
      final dim = state._userScrolling ? 0.6 : state._dimOpacity(distance);
      final opacity = dim + (1 - dim) * emphasis;
      final scale = 0.95 + 0.05 * emphasis;
      final pivot = Offset(width * align, size.height / 2);
      final transform = Matrix4.identity()
        ..translateByDouble(pivot.dx, y + pivot.dy, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1)
        ..translateByDouble(-pivot.dx, -pivot.dy, 0, 1);
      context.paintChild(i, transform: transform, opacity: opacity.clamp(0.0, 1.0));
    }
  }

  @override
  bool shouldRepaint(_LyricsFlowDelegate oldDelegate) => true;

  @override
  bool shouldRelayout(_LyricsFlowDelegate oldDelegate) => false;
}

/// Three dots that fill one after the other over an instrumental gap, breathing, and shrink away as it ends.
class _InterludeDots extends StatelessWidget {
  const _InterludeDots({required this.progress, required this.color, required this.textAlign});

  final ValueListenable<(double, double)> progress;
  final Color color;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: switch (textAlign) {
        TextAlign.center => Alignment.center,
        TextAlign.end || TextAlign.right => AlignmentDirectional.centerEnd,
        _ => AlignmentDirectional.centerStart,
      },
      child: RepaintBoundary(
        child: CustomPaint(size: const Size(64, 24), painter: _DotsPainter(progress, color)),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.progress, this.color) : super(repaint: progress);

  final ValueListenable<(double, double)> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final (p, seconds) = progress.value;
    // Shrink away over the last 8 % so the next line takes over smoothly.
    final exit = p > 0.92 ? 1 - (p - 0.92) / 0.08 : 1.0;
    final breath = 1 + 0.08 * sin(seconds * 2 * pi / 2.4);
    final scale = breath * Curves.easeIn.transform(exit.clamp(0.0, 1.0));
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..scale(scale);
    const radius = 5.0;
    for (var i = 0; i < 3; i++) {
      final own = ((p * 3) - i).clamp(0.0, 1.0);
      canvas.drawCircle(
        Offset((i - 1) * radius * 3.4, 0),
        radius,
        Paint()..color = color.withValues(alpha: 0.3 + 0.7 * own),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DotsPainter oldDelegate) => oldDelegate.color != color || oldDelegate.progress != progress;
}
