import 'dart:io';

import 'package:diapason/screens/desktop/desktop_ambient_background.dart';
import 'package:diapason/screens/desktop/desktop_kit.dart';
import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/current_album_image_provider.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/theme_provider.dart';
import 'package:diapason/utils/device_form_factor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The desktop look on phones and tablets: the app takes the colours of the track playing (accent and surfaces), and
/// every page sits on a soft album-colour field with the blurred cover under a veil, instead of a flat surface.
///
/// It uses the same background layers as the desktop shell and the same setting (`desktopAmbientMode`), so "off"
/// brings back the plain look. Not applied on desktop (the shell does its own), TVs or watches.
class MobileAmbientTheme extends ConsumerWidget {
  const MobileAmbientTheme({super.key, required this.child});

  final Widget child;

  /// Whether this platform gets the ambient look at all.
  static bool get supported => (Platform.isAndroid || Platform.isIOS) && !DeviceFormFactorDetector.current.isTv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = DesktopAmbientMode.fromName(ref.watch(finampSettingsProvider.desktopAmbientMode));
    if (!supported || mode == DesktopAmbientMode.off) return child;
    return PlayerScreenTheme(
      themeTransitionDuration: Duration.zero,
      child: _AmbientLayers(mode: mode, child: child),
    );
  }
}

class _AmbientLayers extends ConsumerWidget {
  const _AmbientLayers({required this.mode, required this.child});

  final DesktopAmbientMode mode;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final image = mode == DesktopAmbientMode.cover ? ref.watch(currentAlbumImageProvider).image : null;
    const fade = Duration(milliseconds: 700);

    final pageTheme = theme.copyWith(
      // Pages and bars are see-through so the background shows; the fade keeps two translucent pages from showing
      // at once while navigating.
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: theme.appBarTheme.copyWith(
        // See-through at rest, a mostly opaque bar once content scrolls under it, so titles stay readable.
        backgroundColor: WidgetStateColor.resolveWith(
          (states) =>
              states.contains(WidgetState.scrolledUnder) ? scheme.surface.withValues(alpha: 0.92) : Colors.transparent,
        ),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final platform in TargetPlatform.values) platform: const DesktopFadeThroughPageTransitionsBuilder(),
        },
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                DesktopColorField(scheme: scheme, duration: fade),
                if (mode == DesktopAmbientMode.cover) DesktopBlurredCover(image: image, duration: fade),
                ColoredBox(color: dark ? Colors.black.withValues(alpha: 0.42) : scheme.surface.withValues(alpha: 0.6)),
              ],
            ),
          ),
        ),
        MobileAmbientScope(
          child: Theme(data: pageTheme, child: child),
        ),
      ],
    );
  }
}

/// Marks the subtree as drawn over the ambient background, so widgets that normally paint an opaque surface (section
/// headers, chips) go translucent. See [translucentSurfaces].
class MobileAmbientScope extends InheritedWidget {
  const MobileAmbientScope({super.key, required super.child});

  @override
  bool updateShouldNotify(MobileAmbientScope oldWidget) => false;
}

/// True inside the desktop shell and on the ambient mobile background: pages sit on a translucent panel there, so
/// opaque header bands and filled chips should give way to faint veils.
bool translucentSurfaces(BuildContext context) =>
    DesktopRouter.isActive || context.getInheritedWidgetOfExactType<MobileAmbientScope>() != null;

/// Background for a header that may stick over scrolling content: transparent over the desktop panel (where it
/// doesn't stick), a mostly opaque veil on the ambient mobile look, the plain surface elsewhere.
Color ambientHeaderColor(BuildContext context, {bool pinned = true}) {
  if (DesktopRouter.isActive) return Colors.transparent;
  final surface = Theme.of(context).colorScheme.surface;
  if (context.getInheritedWidgetOfExactType<MobileAmbientScope>() == null) return surface;
  // At rest the header is see-through; only while it is stuck over scrolling content does it need a backing.
  return pinned ? surface.withValues(alpha: 0.9) : Colors.transparent;
}

/// Headers only stick on mobile; on desktop they scroll away with the page.
bool headersMaySticky(BuildContext context) => !DesktopRouter.isActive;
