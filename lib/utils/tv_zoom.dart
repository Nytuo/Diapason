import 'package:diapason/components/tv_now_playing_pill.dart';
import 'package:diapason/utils/device_form_factor.dart';
import 'package:flutter/material.dart';

/// A TV is read from the sofa and driven with a remote, but its screen is 1920x1080 points, so the phone layouts come
/// out tiny. Instead of a second set of screens, the whole app is laid out as if the screen were smaller and then
/// scaled up: every text, icon and target grows together and the real screens keep all their features.
class TvZoom {
  static const factor = 1.6;

  /// 1 everywhere except on a TV.
  static double get current => DeviceFormFactorDetector.current.isTv ? factor : 1.0;
}

/// Lays [child] out in a box [zoom] times smaller than the space it gets and scales it up to fill that space.
class ZoomBox extends StatelessWidget {
  const ZoomBox({super.key, required this.zoom, required this.child});

  final double zoom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (zoom == 1.0) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth / zoom;
        final height = constraints.maxHeight / zoom;
        final media = MediaQuery.of(context);
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: ClipRect(
            child: Transform.scale(
              scale: zoom,
              alignment: Alignment.topLeft,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: width,
                maxWidth: width,
                minHeight: height,
                maxHeight: height,
                child: MediaQuery(
                  data: media.copyWith(
                    size: Size(width, height),
                    padding: media.padding / zoom,
                    viewPadding: media.viewPadding / zoom,
                    viewInsets: media.viewInsets / zoom,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// For the screens built for the TV from the start (profile picker and the like): they already have TV-sized text,
/// so they cancel the app-wide zoom.
class TvNative extends StatelessWidget {
  const TvNative({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TvPlayerPresence(
    counter: tvOwnChromeScreens,
    child: ZoomBox(zoom: 1 / TvZoom.current, child: child),
  );
}
