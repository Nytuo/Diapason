import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:diapason/services/stats/stats_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// The Wrapped story card: a 9:16 image (1080×1920 when shared) summing up a period of listening.
///
/// It is laid out at a fixed logical size so the picture is the same on every screen, then rendered at 3× for
/// sharing. Colours come from [accent] (the app's theme colour) but the card always uses its own dark palette, so
/// it reads the same in light and dark mode and on whatever app it's posted to.
class WrappedShareCard extends StatelessWidget {
  const WrappedShareCard({super.key, required this.data, required this.accent, this.now});

  final WrappedData data;
  final Color accent;
  final DateTime? now;

  static const size = Size(360, 640);
  static const pixelRatio = 3.0;

  String get _periodTitle {
    final range = data.period.range(now);
    return switch (data.period) {
      WrappedPeriod.thisYear => "${range.start.year}",
      _ => DateFormat.yMMMM().format(range.start),
    };
  }

  String get _periodLine => switch (data.period) {
    WrappedPeriod.thisYear => "My year in music",
    _ => "My month in music",
  };

  static String _number(int value) => NumberFormat.decimalPattern().format(value);

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(accent);
    final deep = hsl.withLightness(0.16).withSaturation(math.min(1, hsl.saturation + 0.1)).toColor();
    final mid = hsl.withHue((hsl.hue + 35) % 360).withLightness(0.32).toColor();
    final glow = hsl.withHue((hsl.hue + 330) % 360).withLightness(0.62).withSaturation(0.9).toColor();
    final bright = hsl.withLightness(0.72).withSaturation(0.95).toColor();

    const white = Colors.white;
    final soft = Colors.white.withValues(alpha: 0.72);
    final faint = Colors.white.withValues(alpha: 0.5);

    final topArtist = data.topArtists.firstOrNull;
    final tracks = data.topTracks.take(5).toList();

    return MediaQuery(
      // The card has to look the same whatever the device's text size.
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: white, height: 1.15),
            child: SizedBox.fromSize(
              size: size,
              child: ClipRect(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [mid, deep, const Color(0xFF07070C)],
                            stops: const [0, 0.55, 1],
                          ),
                        ),
                      ),
                    ),
                    // Soft light blobs for depth.
                    _Blob(color: glow.withValues(alpha: 0.55), diameter: 320, left: -120, top: -90),
                    _Blob(color: bright.withValues(alpha: 0.35), diameter: 260, left: 190, top: 210),
                    _Blob(color: accent.withValues(alpha: 0.4), diameter: 300, left: -90, top: 470),
                    // Concentric rings: a nod to a tuning fork's sound waves.
                    Positioned(right: -70, top: 40, child: _Rings(color: Colors.white.withValues(alpha: 0.09))),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 30, 28, 22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "DIAPASON WRAPPED",
                            style: TextStyle(
                              fontSize: 10.5,
                              letterSpacing: 3,
                              fontWeight: FontWeight.w700,
                              color: soft,
                            ),
                          ),
                          const SizedBox(height: 6),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _periodTitle,
                              style: const TextStyle(
                                fontSize: 46,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1.5,
                                height: 1,
                              ),
                            ),
                          ),
                          Text(
                            _periodLine,
                            style: TextStyle(fontSize: 15, color: soft, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 18),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _number(data.minutesListened),
                              style: TextStyle(
                                fontSize: 56,
                                fontWeight: FontWeight.w900,
                                height: 1,
                                letterSpacing: -2.5,
                                foreground: Paint()
                                  ..shader = LinearGradient(
                                    colors: [white, bright],
                                  ).createShader(const Rect.fromLTWH(0, 0, 300, 56)),
                              ),
                            ),
                          ),
                          Text(
                            "minutes listened",
                            style: TextStyle(fontSize: 14, color: soft, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 16),
                          if (topArtist != null) ...[
                            _Label("TOP ARTIST", color: faint),
                            const SizedBox(height: 4),
                            Text(
                              topArtist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                            ),
                            Text("${_number(topArtist.plays)} plays", style: TextStyle(fontSize: 12.5, color: soft)),
                            const SizedBox(height: 14),
                          ],
                          if (tracks.isNotEmpty) ...[
                            _Label("TOP TRACKS", color: faint),
                            const SizedBox(height: 6),
                            for (final (index, track) in tracks.indexed)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 26,
                                      child: Text(
                                        "${index + 1}",
                                        style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w900,
                                          color: index == 0 ? bright : faint,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            track.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                                          ),
                                          if (track.subtitle.isNotEmpty)
                                            Text(
                                              track.subtitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(fontSize: 11, color: soft),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            child: Row(
                              children: [
                                _Stat(value: _number(data.totalPlays), label: "plays", labelColor: soft),
                                _Stat(value: _number(data.distinctArtists), label: "artists", labelColor: soft),
                                _Stat(value: _number(data.streakDays), label: "day streak", labelColor: soft),
                                _Stat(value: data.dominantGenre ?? "—", label: "top genre", labelColor: soft),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Icon(TablerIcons.wave_sine, size: 16, color: bright),
                              const SizedBox(width: 6),
                              const Text(
                                "diapason",
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 10, letterSpacing: 2.2, fontWeight: FontWeight.w800, color: color),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.labelColor});

  final String value;
  final String label;
  final Color labelColor;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(value, maxLines: 1, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, style: TextStyle(fontSize: 9.5, color: labelColor)),
      ],
    ),
  );
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.diameter, required this.left, required this.top});

  final Color color;
  final double diameter;
  final double left;
  final double top;

  @override
  Widget build(BuildContext context) => Positioned(
    left: left,
    top: top,
    child: ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 50, sigmaY: 50, tileMode: TileMode.decal),
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    ),
  );
}

class _Rings extends StatelessWidget {
  const _Rings({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(220, 220), painter: _RingsPainter(color));
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    final center = size.center(Offset.zero);
    for (var r = 30.0; r <= size.width / 2; r += 22) {
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.color != color;
}

/// Shows the card full screen, scaled to fit, with a button that shares it as a PNG.
Future<void> showWrappedSharePreview(BuildContext context, WrappedData data) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => _WrappedSharePreview(data: data)));
}

class _WrappedSharePreview extends StatefulWidget {
  const _WrappedSharePreview({required this.data});

  final WrappedData data;

  @override
  State<_WrappedSharePreview> createState() => _WrappedSharePreviewState();
}

class _WrappedSharePreviewState extends State<_WrappedSharePreview> {
  final _cardKey = GlobalKey();
  bool _sharing = false;

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final boundary = _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: WrappedShareCard.pixelRatio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;

      final dir = await getTemporaryDirectory();
      final file = File("${dir.path}/diapason-wrapped-${widget.data.period.name}.png");
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);

      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: "image/png")],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't share that.")));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text("Share your Wrapped"),
      ),
      body: SafeArea(
        child: Padding(
          // Room below for the share button.
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
          child: Center(
            child: FittedBox(
              child: RepaintBoundary(
                key: _cardKey,
                child: WrappedShareCard(data: widget.data, accent: Theme.of(context).colorScheme.primary),
              ),
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _sharing ? null : _share,
        icon: _sharing
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(TablerIcons.share),
        label: const Text("Share image"),
      ),
    );
  }
}
