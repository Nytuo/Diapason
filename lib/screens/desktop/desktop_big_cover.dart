import 'package:diapason/components/album_image.dart';
import 'package:diapason/extensions/localizations.dart';
import 'package:diapason/screens/desktop/desktop_kit.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/current_album_image_provider.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// The current cover, large, at the bottom of the sidebar (Feishin's sidebar
/// image). Shown while [FinampSettings.desktopBigCoverArt] is on and a track is
/// loaded; the button on it hides it (clicking the art does nothing).
class DesktopBigCover extends ConsumerStatefulWidget {
  const DesktopBigCover({super.key});

  @override
  ConsumerState<DesktopBigCover> createState() => _DesktopBigCoverState();
}

class _DesktopBigCoverState extends ConsumerState<DesktopBigCover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final enabled = ref.watch(finampSettingsProvider.desktopBigCoverArt);
    final hasTrack = ref.watch(currentTrackProvider).value != null;
    final show = enabled && hasTrack;
    final duration = p.motion(const Duration(milliseconds: 260));
    return AnimatedSize(
      duration: duration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: !show
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: AspectRatio(
                aspectRatio: 1,
                child: MouseRegion(
                  cursor: SystemMouseCursors.basic,
                  onEnter: (_) => setState(() => _hover = true),
                  onExit: (_) => setState(() => _hover = false),
                  child: _cover(context, p),
                ),
              ),
            ),
    );
  }

  Widget _cover(BuildContext context, DesktopPalette p) {
    final radius = BorderRadius.circular(DesktopMetrics.radiusCard);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: p.isDark ? 0.45 : 0.18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AlbumImage(imageListenable: currentAlbumImageProvider, borderRadius: BorderRadius.zero),
            AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: p.motion(const Duration(milliseconds: 150)),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.45),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.25),
                    ],
                    stops: const [0, 0.4, 1],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: 8,
                      right: 8,
                      child: DesktopCircleButton(
                        icon: TablerIcons.chevron_down,
                        tooltip: context.l10n.desktopStyleHideBigCover,
                        color: Colors.black.withValues(alpha: 0.45),
                        iconColor: Colors.white,
                        onPressed: () => FinampSetters.setDesktopBigCoverArt(false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
