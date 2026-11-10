import 'dart:math';

import 'package:diapason/components/print_duration.dart';
import 'package:diapason/models/jellyfin_models.dart' as jellyfin_models;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Where each chapter after the first begins, as fractions (0..1, exclusive) of the track, sorted.
List<double> chapterBoundaries(List<jellyfin_models.ChapterInfo> chapters, Duration duration) {
  final total = duration.inMicroseconds;
  if (total <= 0) return const [];
  final boundaries = <double>[
    for (final chapter in chapters)
      if (chapter.startPosition.inMicroseconds > 0 && chapter.startPosition.inMicroseconds < total)
        chapter.startPosition.inMicroseconds / total,
  ]..sort();
  return boundaries;
}

/// Index of the segment containing [fraction], given the [boundaries] between segments.
int segmentAt(List<double> boundaries, double fraction) {
  var index = 0;
  while (index < boundaries.length && fraction >= boundaries[index]) {
    index++;
  }
  return index;
}

/// A slider track split into one segment per chapter, with a small gap between them (like YouTube). Each segment
/// shows its own played, buffered and unplayed parts, and the [hoveredSegment] is drawn taller.
///
/// With no [boundaries] it is a plain full-width track, so it can be used whether or not the item has chapters.
class ChapterTrackShape extends SliderTrackShape {
  const ChapterTrackShape({
    this.boundaries = const [],
    this.hoveredSegment,
    this.gap = 3.0,
    this.hoverHeightFactor = 1.8,
    this.rounded = true,
  });

  final List<double> boundaries;
  final int? hoveredSegment;

  /// Space between two segments, in logical pixels.
  final double gap;

  /// How much taller the hovered segment is drawn.
  final double hoverHeightFactor;

  final bool rounded;

  @override
  bool get isRounded => rounded;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final height = sliderTheme.trackHeight ?? 4.0;
    return Rect.fromLTWH(offset.dx, offset.dy + (parentBox.size.height - height) / 2, parentBox.size.width, height);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final track = getPreferredRect(parentBox: parentBox, offset: offset, sliderTheme: sliderTheme);
    if (track.width <= 0 || track.height <= 0) return;

    final enabledness = enableAnimation.value;
    Color pick(Color? enabled, Color? disabled, Color fallback) =>
        Color.lerp(disabled ?? enabled ?? fallback, enabled ?? fallback, enabledness)!;
    final inactive = pick(sliderTheme.inactiveTrackColor, sliderTheme.disabledInactiveTrackColor, Colors.grey);
    final buffered = pick(
      sliderTheme.secondaryActiveTrackColor,
      sliderTheme.disabledSecondaryActiveTrackColor,
      Colors.transparent,
    );
    final active = pick(sliderTheme.activeTrackColor, sliderTheme.disabledActiveTrackColor, Colors.blue);

    final ltr = textDirection == TextDirection.ltr;
    double progressFraction(double x) => ((ltr ? x - track.left : track.right - x) / track.width).clamp(0.0, 1.0);
    final played = progressFraction(thumbCenter.dx);
    final loaded = secondaryOffset == null ? 0.0 : progressFraction(secondaryOffset.dx);

    final canvas = context.canvas;
    final paint = Paint();
    final edges = [0.0, ...boundaries, 1.0];
    final halfGap = boundaries.isEmpty ? 0.0 : min(gap, track.width / (edges.length * 4)) / 2;

    for (var i = 0; i < edges.length - 1; i++) {
      final start = edges[i], end = edges[i + 1];
      final left = track.width * start + (i == 0 ? 0 : halfGap);
      final right = track.width * end - (i == edges.length - 2 ? 0 : halfGap);
      if (right <= left) continue;

      final height = i == hoveredSegment ? track.height * hoverHeightFactor : track.height;
      final top = track.center.dy - height / 2;
      final radius = rounded ? Radius.circular(height / 2) : Radius.zero;

      Rect span(double from, double to) {
        // Fractions of the whole track, clipped to this segment, mirrored for right-to-left.
        final a = (track.width * from).clamp(left, right), b = (track.width * to).clamp(left, right);
        return ltr
            ? Rect.fromLTRB(track.left + a, top, track.left + b, top + height)
            : Rect.fromLTRB(track.right - b, top, track.right - a, top + height);
      }

      final whole = RRect.fromRectAndRadius(span(start, end), radius);
      canvas.drawRRect(whole, paint..color = inactive);

      canvas.save();
      canvas.clipRRect(whole);
      if (loaded > start) canvas.drawRect(span(start, loaded), paint..color = buffered);
      if (played > start) canvas.drawRect(span(start, played), paint..color = active);
      canvas.restore();
    }
  }
}

/// Tracks which chapter segment the mouse is over, hands it to [builder] (for [ChapterTrackShape.hoveredSegment]),
/// and shows that chapter's name and start time above the pointer.
class ChapterHoverRegion extends StatefulWidget {
  const ChapterHoverRegion({
    super.key,
    required this.chapters,
    required this.duration,
    required this.builder,
    this.enabled = true,
  });

  final List<jellyfin_models.ChapterInfo> chapters;
  final Duration duration;
  final bool enabled;
  final Widget Function(BuildContext context, List<double> boundaries, int? hoveredSegment) builder;

  @override
  State<ChapterHoverRegion> createState() => _ChapterHoverRegionState();
}

class _ChapterHoverRegionState extends State<ChapterHoverRegion> {
  final _overlay = OverlayPortalController();
  int? _hovered;
  Offset? _pointer;
  String? _label;

  void _onHover(PointerHoverEvent event, List<double> boundaries) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.width <= 0) return;
    final fraction = (event.localPosition.dx / box.size.width).clamp(0.0, 1.0);
    final segment = segmentAt(boundaries, fraction);
    final at = Duration(microseconds: (widget.duration.inMicroseconds * fraction).round());
    jellyfin_models.ChapterInfo? chapter;
    for (final candidate in widget.chapters) {
      if (candidate.startPosition <= at) chapter = candidate;
    }
    final name = chapter?.name?.isNotEmpty ?? false ? chapter!.name! : null;
    setState(() {
      _hovered = segment;
      _pointer = box.localToGlobal(Offset(event.localPosition.dx, 0));
      _label = name == null ? printDuration(at) : "$name · ${printDuration(at)}";
    });
    if (!_overlay.isShowing) _overlay.show();
  }

  void _onExit() {
    if (_overlay.isShowing) _overlay.hide();
    setState(() {
      _hovered = null;
      _pointer = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final boundaries = chapterBoundaries(widget.chapters, widget.duration);
    final child = widget.builder(context, boundaries, _hovered);
    if (!widget.enabled || boundaries.isEmpty) return child;

    return OverlayPortal(
      controller: _overlay,
      overlayChildBuilder: (context) {
        final pointer = _pointer;
        final label = _label;
        if (pointer == null || label == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Positioned(
          left: pointer.dx,
          top: pointer.dy,
          child: IgnorePointer(
            child: FractionalTranslation(
              translation: const Offset(-0.5, -1.15),
              child: Material(
                color: theme.colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onInverseSurface),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: MouseRegion(onHover: (event) => _onHover(event, boundaries), onExit: (_) => _onExit(), child: child),
    );
  }
}
