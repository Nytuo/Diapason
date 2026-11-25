import 'package:diapason/components/album_image.dart';
import 'package:diapason/components/favorite_button.dart';
import 'package:diapason/components/print_duration.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/components/MusicScreen/item_wrapper.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/current_album_image_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Building blocks of the desktop design system. They read every colour and
/// size from [DesktopThemeScope] and [DesktopMetrics], so a page built from
/// them follows the theme, the ambient background and "reduce effects".

/// A rounded, floating container: the sidebar, the content area, the player
/// bar and side panels are all one of these.
class DesktopPanel extends StatelessWidget {
  const DesktopPanel({
    super.key,
    required this.child,
    this.color,
    this.radius = DesktopMetrics.radiusPanel,
    this.padding,
    this.width,
    this.height,
    this.chrome = false,
  });

  final Widget child;

  /// Fill; defaults to the palette's [DesktopPalette.panel] (or
  /// [DesktopPalette.chrome] when [chrome]).
  final Color? color;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  /// Paint as window chrome (sidebar, player bar) rather than content.
  final bool chrome;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: p.panelBorder),
    );
    return Container(
      width: width,
      height: height,
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(color: color ?? (chrome ? p.chrome : p.panel), shape: shape),
      child: child,
    );
  }
}

/// A section title with optional actions and paging arrows on the right, as
/// above the home page's shelves.
class DesktopSectionHeader extends StatelessWidget {
  const DesktopSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.onPrevious,
    this.onNext,
    this.onTitleTap,
    this.showPaging = false,
    this.previousTooltip,
    this.nextTooltip,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onTitleTap;

  /// Show the previous / next arrows (disabled when their callback is null).
  final bool showPaging;
  final String? previousTooltip;
  final String? nextTooltip;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    Widget titleText = Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.section);
    if (onTitleTap != null) {
      titleText = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTitleTap, child: titleText),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Expanded (not Flexible + Spacer, which split the free space and left the actions mid-row).
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                titleText,
                if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: p.caption)],
              ],
            ),
          ),
        ),
        ...actions,
        if (showPaging) ...[
          if (actions.isNotEmpty) const SizedBox(width: 8),
          DesktopCircleButton(icon: Icons.chevron_left_rounded, tooltip: previousTooltip, onPressed: onPrevious),
          const SizedBox(width: 6),
          DesktopCircleButton(icon: Icons.chevron_right_rounded, tooltip: nextTooltip, onPressed: onNext),
        ],
      ],
    );
  }
}

/// A small round icon button on a translucent fill (shelf arrows, card
/// actions).
class DesktopCircleButton extends StatelessWidget {
  const DesktopCircleButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.size = 28,
    this.iconSize = 18,
    this.filled = true,
    this.color,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;
  final bool filled;
  final Color? color;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final enabled = onPressed != null;
    final button = Material(
      color: filled ? (color ?? p.surface) : Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        hoverColor: p.surfaceHover,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: iconSize,
            color: (iconColor ?? p.textSecondary).withValues(alpha: enabled ? 1 : 0.35),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Fades the outgoing page out, then the incoming one in, lifting it a few pixels and growing it from 98%. Used
/// inside the content panel, where pages are translucent and a slide would show both at once. Instant when the
/// "reduce effects" setting is on.
class DesktopFadeThroughPageTransitionsBuilder extends PageTransitionsBuilder {
  const DesktopFadeThroughPageTransitionsBuilder({this.reduceEffects = false});

  final bool reduceEffects;

  @override
  Duration get transitionDuration => reduceEffects ? Duration.zero : const Duration(milliseconds: 260);

  @override
  Duration get reverseTransitionDuration => reduceEffects ? Duration.zero : const Duration(milliseconds: 200);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceEffects) return child;
    final enter = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.25, 1, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: const Interval(0, 0.35, curve: Curves.easeIn),
        ),
      ),
      child: FadeTransition(
        opacity: enter,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(enter),
          child: ScaleTransition(scale: Tween<double>(begin: 0.985, end: 1).animate(enter), child: child),
        ),
      ),
    );
  }
}

/// A compact track row, after Chilpa's lists: art, title and artist, album, duration, favourite and a menu.
/// Tapping plays [queue] from this track.
class DesktopTrackRow extends ConsumerStatefulWidget {
  const DesktopTrackRow({
    super.key,
    required this.item,
    required this.index,
    required this.queue,
    required this.source,
    this.showNumber = false,
  });

  final BaseItemDto item;
  final int index;
  final List<BaseItemDto> queue;
  final QueueItemSource source;

  /// Show the track number instead of the cover.
  final bool showNumber;

  @override
  ConsumerState<DesktopTrackRow> createState() => _DesktopTrackRowState();
}

class _DesktopTrackRowState extends ConsumerState<DesktopTrackRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final item = widget.item;
    final artists = (item.artists ?? const <String>[]).join(", ");
    final duration = item.runTimeTicksDuration();
    // The row of the track now playing is highlighted, like Chilpa's.
    final playing = ref.watch(currentTrackProvider.select((t) => t.value?.baseItem.id)) == item.id;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => GetIt.instance<QueueService>().startPlayback(
          items: widget.queue,
          source: widget.source,
          startingIndex: widget.index,
        ),
        onSecondaryTap: () => openItemMenu(context: context, item: item),
        child: Container(
          height: 52,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: playing ? p.accentMuted : (_hover ? p.surfaceHover : Colors.transparent),
            borderRadius: BorderRadius.circular(DesktopMetrics.radiusItem),
          ),
          child: Row(
            children: [
              SizedBox(
                width: widget.showNumber ? 40 : 54,
                child: playing && widget.showNumber
                    ? Icon(TablerIcons.player_play_filled, size: 14, color: p.accent)
                    : widget.showNumber
                    ? Text(
                        "${item.indexNumber ?? widget.index + 1}",
                        style: TextStyle(color: p.textTertiary, fontSize: 13),
                      )
                    // Align gives the cover loose constraints: inside the tight-width slot it would otherwise be
                    // stretched to a non-square box, which the image provider rejects.
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(DesktopMetrics.radiusArtSmall),
                          child: SizedBox(width: 38, height: 38, child: AlbumImage(item: item)),
                        ),
                      ),
              ),
              Expanded(
                flex: 5,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name ?? "",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: playing ? p.accent : p.textPrimary,
                        fontSize: 14,
                        fontWeight: playing ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (artists.isNotEmpty)
                      Text(
                        artists,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textSecondary, fontSize: 12),
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  item.album ?? "",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.textSecondary, fontSize: 13),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  duration == null ? "" : printDuration(duration),
                  textAlign: TextAlign.end,
                  style: TextStyle(color: p.textSecondary, fontSize: 13),
                ),
              ),
              const SizedBox(width: 4),
              FavoriteButton(item: item, color: p.textSecondary, size: 18),
              IconButton(
                iconSize: 18,
                color: p.textSecondary,
                tooltip: "More",
                icon: const Icon(TablerIcons.dots),
                onPressed: () => openItemMenu(context: context, item: item),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
