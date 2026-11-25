import 'dart:async';
import 'dart:ui' as ui;

import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/current_album_image_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The bottom-most layer of the desktop window: under every panel, one of the
/// [DesktopAmbientMode] looks and its legibility veil.
///
/// Cheap by design: the album-colour field is four static radial gradients,
/// and the cover is blurred once per album into a tiny bitmap
/// ([DesktopBlurredCoverCache]) that is only scaled up here; nothing blurs
/// per frame and there is no BackdropFilter anywhere in the window.
class DesktopAmbientBackground extends ConsumerWidget {
  const DesktopAmbientBackground({super.key, required this.mode});

  final DesktopAmbientMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = DesktopThemeScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final image = mode == DesktopAmbientMode.cover ? ref.watch(currentAlbumImageProvider).image : null;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: p.window),
          if (mode != DesktopAmbientMode.off) DesktopColorField(scheme: scheme, duration: p.motion(_fade)),
          if (mode == DesktopAmbientMode.cover) DesktopBlurredCover(image: image, duration: p.motion(_fade)),
          if (mode != DesktopAmbientMode.off) ColoredBox(color: p.veil),
        ],
      ),
    );
  }

  static const _fade = Duration(milliseconds: 700);
}

/// A soft field of the album's colours: four large radial lobes over the
/// surface colour, after Chilpa's ambient field (without its animation).
class DesktopColorField extends StatelessWidget {
  const DesktopColorField({super.key, required this.scheme, this.duration = Duration.zero});

  final ColorScheme scheme;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final dark = scheme.brightness == Brightness.dark;
    final lobes = <(Alignment, Color, double)>[
      (const Alignment(-0.85, -0.9), scheme.primary, dark ? 0.55 : 0.45),
      (const Alignment(0.9, -0.55), scheme.tertiary, dark ? 0.45 : 0.38),
      (const Alignment(-0.45, 0.95), scheme.secondary, dark ? 0.42 : 0.34),
      (const Alignment(0.75, 0.85), scheme.primaryContainer, dark ? 0.50 : 0.42),
    ];
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedContainer(duration: duration, color: dark ? scheme.surfaceContainerLowest : scheme.surfaceContainer),
        for (final (center, color, alpha) in lobes)
          AnimatedContainer(
            duration: duration,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: center,
                radius: 1.1,
                colors: [
                  color.withValues(alpha: alpha),
                  color.withValues(alpha: 0),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The current cover, blurred once into a small bitmap and stretched over the
/// window. Cross-fades between albums unless [duration] is zero.
class DesktopBlurredCover extends StatefulWidget {
  const DesktopBlurredCover({super.key, required this.image, this.duration = Duration.zero});

  final ImageProvider? image;
  final Duration duration;

  @override
  State<DesktopBlurredCover> createState() => _DesktopBlurredCoverState();
}

class _DesktopBlurredCoverState extends State<DesktopBlurredCover> {
  ui.Image? _blurred;
  ImageProvider? _for;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DesktopBlurredCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _load();
  }

  Future<void> _load() async {
    final provider = widget.image;
    _for = provider;
    if (provider == null) {
      _set(null);
      return;
    }
    final image = await DesktopBlurredCoverCache.instance.blurred(provider);
    if (!mounted || _for != provider) {
      image?.dispose();
      return;
    }
    _set(image);
  }

  void _set(ui.Image? image) {
    final old = _blurred;
    setState(() => _blurred = image);
    // The old handle stays on screen while the switcher fades it out.
    if (old != null) Timer(widget.duration + const Duration(milliseconds: 100), old.dispose);
  }

  @override
  void dispose() {
    _blurred?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _blurred;
    return AnimatedSwitcher(
      duration: widget.duration,
      child: image == null
          ? const SizedBox.expand()
          : SizedBox.expand(
              key: ValueKey(_for),
              child: RawImage(
                // The switcher keeps the old child around while it fades, so
                // each child holds its own handle.
                image: image,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              ),
            ),
    );
  }
}

/// Blurs covers into small bitmaps, once per cover, and keeps the last few.
class DesktopBlurredCoverCache {
  DesktopBlurredCoverCache._();

  static final instance = DesktopBlurredCoverCache._();

  /// Side of the blurred bitmap. Small on purpose: scaled up with bicubic
  /// filtering it reads as a heavy blur, at the cost of a few kilobytes.
  static const int side = 64;
  static const double sigma = 5;
  static const int capacity = 8;

  // Insertion-ordered: the first key is the least recently used.
  final Map<ImageProvider, Future<ui.Image?>> _cache = {};

  /// A new handle to the blurred bitmap of [provider] (the caller disposes it),
  /// or null when the image can't be loaded.
  Future<ui.Image?> blurred(ImageProvider provider) async {
    var future = _cache.remove(provider);
    future ??= _blur(provider);
    _cache[provider] = future; // most recently used last
    while (_cache.length > capacity) {
      final evicted = _cache.remove(_cache.keys.first);
      unawaited(evicted?.then((image) => image?.dispose()));
    }
    final image = await future;
    // The cache may have evicted (and disposed) it while we waited.
    if (image == null || !identical(_cache[provider], future)) return null;
    return image.clone();
  }

  static Future<ui.Image?> _blur(ImageProvider provider) async {
    final source = await _decode(ResizeImage(provider, width: side * 2, height: side * 2));
    if (source == null) return null;
    try {
      return await blurImage(source, side: side, sigma: sigma);
    } finally {
      source.dispose();
    }
  }

  /// Draws [source] blurred into a [side]×[side] bitmap.
  static Future<ui.Image> blurImage(ui.Image source, {int side = side, double sigma = sigma}) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final bounds = Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble());
    canvas.saveLayer(
      bounds,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.mirror),
    );
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      bounds,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    final picture = recorder.endRecording();
    return picture.toImage(side, side).whenComplete(picture.dispose);
  }

  static Future<ui.Image?> _decode(ImageProvider provider) {
    final completer = Completer<ui.Image?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image.clone());
        info.dispose();
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }
}
