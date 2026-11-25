import 'dart:math';
import 'dart:ui' as ui;

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/furigana.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// How much of a line is sung: characters before [litEnd] are fully lit, and the word `[wordStart, wordEnd)` is lit
/// up to [progress] (0–1) of its width.
@immutable
class LyricFill {
  const LyricFill({this.litEnd = 0, this.wordStart = 0, this.wordEnd = 0, this.progress = 0});

  final int litEnd;
  final int wordStart;
  final int wordEnd;
  final double progress;

  static const none = LyricFill();

  /// Where a line stands at [micros] (in the lyrics' timeline). Word cues give a per-word sweep; a line without them
  /// is swept as one word, from its start until [lineEndMicros] (or an estimate from its length).
  static LyricFill at(LyricLine line, int micros, {int? lineEndMicros}) {
    final text = line.text ?? "";
    if (text.isEmpty) return none;
    final cues = line.cues;
    if (cues != null && cues.isNotEmpty) {
      var litEnd = 0;
      for (var i = 0; i < cues.length; i++) {
        final cue = cues[i];
        final next = i + 1 < cues.length ? cues[i + 1] : null;
        final end = (cue.endPosition ?? next?.position ?? text.length).clamp(0, text.length);
        final start = cue.position.clamp(0, end);
        final endTime = cue.endMicros ?? next?.startMicros;
        if (micros < cue.startMicros) break;
        if (endTime != null && micros >= endTime) {
          litEnd = max(litEnd, end);
          continue;
        }
        final length = endTime == null ? 0 : endTime - cue.startMicros;
        final progress = length <= 0 ? 1.0 : ((micros - cue.startMicros) / length).clamp(0.0, 1.0);
        return LyricFill(litEnd: litEnd, wordStart: start, wordEnd: end, progress: progress);
      }
      return LyricFill(litEnd: litEnd);
    }
    final start = line.startMicros;
    // Lines usually take about as long as their syllables; don't stretch the sweep across a long instrumental.
    final estimated = start + max(1500000, text.length * 110000);
    final end = lineEndMicros == null ? estimated : min(lineEndMicros, estimated);
    if (micros <= start) return none;
    if (micros >= end) return LyricFill(litEnd: text.length);
    return LyricFill(wordEnd: text.length, progress: (micros - start) / (end - start));
  }

  @override
  bool operator ==(Object other) =>
      other is LyricFill &&
      other.litEnd == litEnd &&
      other.wordStart == wordStart &&
      other.wordEnd == wordEnd &&
      (other.progress - progress).abs() < 0.002;

  @override
  int get hashCode => Object.hash(litEnd, wordStart, wordEnd, (progress * 500).round());

  @override
  String toString() => "LyricFill(lit: $litEnd, word: $wordStart-$wordEnd @ ${progress.toStringAsFixed(2)})";
}

/// A lyric line painted directly: furigana [ruby] above the kanji, and, when [fill] is given, the sung part in
/// [fillColor] with a soft gradient edge sweeping through the current word, over the rest in [color].
///
/// Only paint is redone when [fill] changes, so the active line can update every frame without relayout.
class LyricText extends LeafRenderObjectWidget {
  const LyricText({
    super.key,
    required this.text,
    required this.style,
    required this.color,
    this.textAlign = TextAlign.start,
    this.ruby = const [],
    this.fillColor,
    this.fill,
  });

  final String text;
  final TextStyle style;
  final Color color;
  final TextAlign textAlign;
  final List<RubySegment> ruby;
  final Color? fillColor;
  final ValueListenable<LyricFill>? fill;

  @override
  RenderLyricText createRenderObject(BuildContext context) => RenderLyricText(
    text: text,
    style: style,
    color: color,
    textAlign: textAlign,
    ruby: ruby,
    fillColor: fillColor,
    fill: fill,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  );

  @override
  void updateRenderObject(BuildContext context, RenderLyricText renderObject) {
    renderObject
      ..text = text
      ..style = style
      ..color = color
      ..textAlign = textAlign
      ..ruby = ruby
      ..fillColor = fillColor
      ..fill = fill
      ..textDirection = Directionality.of(context)
      ..textScaler = MediaQuery.textScalerOf(context);
  }
}

class RenderLyricText extends RenderBox {
  RenderLyricText({
    required String text,
    required TextStyle style,
    required Color color,
    required TextAlign textAlign,
    required List<RubySegment> ruby,
    required Color? fillColor,
    required ValueListenable<LyricFill>? fill,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) : _text = text,
       _style = style,
       _color = color,
       _textAlign = textAlign,
       _ruby = ruby,
       _fillColor = fillColor,
       _fill = fill,
       _textDirection = textDirection,
       _textScaler = textScaler;

  /// Ruby size relative to the text.
  static const rubyScale = 0.46;

  String _text;
  set text(String value) {
    if (value == _text) return;
    _text = value;
    _invalidate();
  }

  TextStyle _style;
  set style(TextStyle value) {
    if (value == _style) return;
    _style = value;
    _invalidate();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    _base?.dispose();
    _base = null;
    _disposeRuby();
    markNeedsPaint();
  }

  TextAlign _textAlign;
  set textAlign(TextAlign value) {
    if (value == _textAlign) return;
    _textAlign = value;
    _invalidate();
  }

  List<RubySegment> _ruby;
  set ruby(List<RubySegment> value) {
    if (listEquals(value, _ruby)) return;
    _ruby = value;
    _invalidate();
  }

  Color? _fillColor;
  set fillColor(Color? value) {
    if (value == _fillColor) return;
    _fillColor = value;
    _bright?.dispose();
    _bright = null;
    _disposeRuby();
    markNeedsPaint();
  }

  ValueListenable<LyricFill>? _fill;
  set fill(ValueListenable<LyricFill>? value) {
    if (value == _fill) return;
    if (attached) _fill?.removeListener(markNeedsPaint);
    _fill = value;
    if (attached) _fill?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    _invalidate();
  }

  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _invalidate();
  }

  TextPainter? _base;
  TextPainter? _bright;
  List<(RubySegment, TextPainter)>? _rubyBase;
  List<(RubySegment, TextPainter)>? _rubyBright;
  double? _laidOutWidth;

  void _invalidate() {
    _base?.dispose();
    _bright?.dispose();
    _base = null;
    _bright = null;
    _disposeRuby();
    _laidOutWidth = null;
    markNeedsLayout();
  }

  void _disposeRuby() {
    for (final (_, p) in [...?_rubyBase, ...?_rubyBright]) {
      p.dispose();
    }
    _rubyBase = null;
    _rubyBright = null;
  }

  bool get _hasRuby => _ruby.isNotEmpty;

  TextStyle get _lineStyle => _hasRuby
      // Room above each wrapped line for the readings: proportional leading puts most of the extra height above.
      ? _style.copyWith(height: 1.9, leadingDistribution: TextLeadingDistribution.proportional)
      : _style;

  TextPainter _painter(Color color, double width) => TextPainter(
    text: TextSpan(
      text: _text,
      style: _lineStyle.copyWith(color: color),
    ),
    textAlign: _textAlign,
    textDirection: _textDirection,
    textScaler: _textScaler,
  )..layout(minWidth: width.isFinite ? width : 0, maxWidth: width);

  TextPainter get _laidOutBase => _base ??= _painter(_color, _laidOutWidth ?? constraints.maxWidth);

  TextPainter get _laidOutBright => _bright ??= _painter(_fillColor ?? _color, _laidOutWidth ?? constraints.maxWidth);

  List<(RubySegment, TextPainter)> _rubyPainters(Color color) => [
    for (final segment in _ruby)
      if (segment.start >= 0 && segment.end <= _text.length && segment.start < segment.end)
        (
          segment,
          TextPainter(
            text: TextSpan(
              text: segment.reading,
              style: _style.copyWith(
                color: color,
                fontSize: (_style.fontSize ?? 14) * rubyScale,
                height: 1.0,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
            textDirection: _textDirection,
            textScaler: _textScaler,
            maxLines: 1,
          )..layout(),
        ),
  ];

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _fill?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _fill?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _base?.dispose();
    _bright?.dispose();
    _disposeRuby();
    super.dispose();
  }

  @override
  // Must never change after the first paint (Flutter asserts on it), and `fill` toggles as lines become active.
  bool get isRepaintBoundary => true;

  @override
  double computeMinIntrinsicHeight(double width) => _measure(width).height;

  @override
  double computeMaxIntrinsicHeight(double width) => _measure(width).height;

  @override
  double computeMaxIntrinsicWidth(double height) {
    final p = _painter(_color, double.infinity);
    final w = p.maxIntrinsicWidth;
    p.dispose();
    return w;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final p = _painter(_color, 0);
    final w = p.minIntrinsicWidth;
    p.dispose();
    return w;
  }

  Size _measure(double width) {
    final p = _painter(_color, width);
    final size = p.size;
    p.dispose();
    return size;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(_measure(constraints.maxWidth));

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    if (_laidOutWidth != width) {
      _base?.dispose();
      _bright?.dispose();
      _base = null;
      _bright = null;
      _laidOutWidth = width;
    }
    final painter = _laidOutBase;
    size = constraints.constrain(painter.size);
  }

  void _paintText(Canvas canvas, Offset offset, TextPainter painter, List<(RubySegment, TextPainter)> ruby) {
    painter.paint(canvas, offset);
    for (final (segment, rubyPainter) in ruby) {
      final boxes = _laidOutBase.getBoxesForSelection(
        TextSelection(baseOffset: segment.start, extentOffset: segment.end),
      );
      if (boxes.isEmpty) continue;
      final box = boxes.first.toRect();
      rubyPainter.paint(
        canvas,
        offset +
            Offset(
              // Centred over the kanji, but kept inside the line when the reading is wider.
              (box.center.dx - rubyPainter.width / 2).clamp(0.0, max(0.0, size.width - rubyPainter.width)),
              box.top - rubyPainter.height * 0.95,
            ),
      );
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final origin = offset;
    final base = _laidOutBase;
    _rubyBase ??= _rubyPainters(_color);
    _paintText(canvas, origin, base, _rubyBase!);

    final fill = _fill?.value;
    if (fill == null || _fillColor == null || (fill.litEnd <= 0 && fill.wordEnd <= fill.wordStart)) return;
    final bright = _laidOutBright;
    _rubyBright ??= _rubyPainters(_fillColor!);

    // Full-height boxes, so the readings above are lit along with their kanji.
    List<Rect> boxes(int from, int to) => [
      for (final b in base.getBoxesForSelection(
        TextSelection(baseOffset: from, extentOffset: to),
        boxHeightStyle: ui.BoxHeightStyle.max,
      ))
        b.toRect().shift(origin),
    ];

    final litEnd = fill.litEnd.clamp(0, _text.length);
    if (litEnd > 0) {
      final path = Path();
      for (final r in boxes(0, litEnd)) {
        path.addRect(r.inflate(0.5));
      }
      canvas
        ..save()
        ..clipPath(path);
      _paintText(canvas, origin, bright, _rubyBright!);
      canvas.restore();
    }

    final start = fill.wordStart.clamp(0, _text.length);
    final end = fill.wordEnd.clamp(start, _text.length);
    if (end <= start || fill.progress <= 0) return;
    final wordBoxes = boxes(start, end);
    final total = wordBoxes.fold<double>(0, (sum, r) => sum + r.width);
    if (total <= 0) return;
    final rtl = _textDirection == TextDirection.rtl;
    var remaining = total * fill.progress;
    // The soft edge: wide enough to read as a glow, never wider than a few letters.
    final feather = min(28.0, max(8.0, (_style.fontSize ?? 20) * 0.9));
    for (final r in wordBoxes) {
      if (remaining <= 0) break;
      if (remaining >= r.width + feather / 2) {
        canvas
          ..save()
          ..clipRect(r.inflate(0.5));
        _paintText(canvas, origin, bright, _rubyBright!);
        canvas.restore();
      } else {
        final edge = rtl ? r.right - remaining : r.left + remaining;
        final from = (edge - feather / 2 - r.left) / r.width;
        final to = (edge + feather / 2 - r.left) / r.width;
        final opaque = const Color(0xFFFFFFFF);
        final clear = const Color(0x00FFFFFF);
        canvas.saveLayer(r.inflate(0.5), Paint());
        _paintText(canvas, origin, bright, _rubyBright!);
        canvas.drawRect(
          r.inflate(0.5),
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = ui.Gradient.linear(
              r.centerLeft,
              r.centerRight,
              rtl ? [clear, clear, opaque, opaque] : [opaque, opaque, clear, clear],
              [0.0, from.clamp(0.0, 1.0), to.clamp(0.0, 1.0), 1.0],
            ),
        );
        canvas.restore();
      }
      remaining -= r.width;
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;
}
