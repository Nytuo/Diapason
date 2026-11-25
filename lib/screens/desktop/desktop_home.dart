import 'dart:math';
import 'dart:ui';

import 'package:diapason/components/MusicScreen/item_card.dart';
import 'package:diapason/components/MusicScreen/item_wrapper.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/extensions/localizations.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_models.dart';
import 'package:diapason/screens/album_screen.dart';
import 'package:diapason/screens/desktop/desktop_kit.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/genre_screen.dart';
import 'package:diapason/screens/home_screen_settings_screen.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_providers.dart';
import 'package:diapason/services/music_screen_provider.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';

/// Random albums for the featured carousel. One instance for the app's life:
/// [HomeScreenSectionConfiguration] has no value equality, and the providers
/// are keyed on it.
final desktopFeaturedSection = HomeScreenSectionConfiguration(
  base: TabsHomeSection(libraryId: currentLibraryPlaceholder, contentType: ContentType.albums),
  sortConfig: SortAndFilterConfiguration(sortBy: SortBy.random, sortOrder: SortOrder.ascending, filters: {}),
  customSectionTitle: "Featured",
);

/// A random handful of genres for the genre grid.
final desktopGenresSection = HomeScreenSectionConfiguration(
  base: TabsHomeSection(libraryId: currentLibraryPlaceholder, contentType: ContentType.genres),
  sortConfig: SortAndFilterConfiguration(sortBy: SortBy.random, sortOrder: SortOrder.ascending, filters: {}),
  customSectionTitle: "Genres",
);

/// The desktop home page, after Feishin's: a featured carousel, a grid of
/// genres, then one horizontal shelf per home section the user configured
/// (the same sections and data as the mobile home screen).
class DesktopHome extends ConsumerWidget {
  const DesktopHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(finampSettingsProvider.homeScreenConfiguration).sections;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          DesktopMetrics.pagePadding,
          4,
          DesktopMetrics.pagePadding,
          DesktopMetrics.pagePadding + 16,
        ),
        children: [
          const DesktopFeaturedCarousel(),
          const SizedBox(height: DesktopMetrics.sectionGap),
          const DesktopGenreGrid(),
          for (final section in sections) ...[
            const SizedBox(height: DesktopMetrics.sectionGap),
            DesktopShelf(key: ValueKey(section), section: section),
          ],
          const SizedBox(height: DesktopMetrics.sectionGap),
          Center(
            child: TextButton.icon(
              icon: const Icon(TablerIcons.settings, size: 16),
              label: Text(context.l10n.desktopStyleCustomizeHome),
              onPressed: () => Navigator.of(context, rootNavigator: true).pushNamed(HomeScreenSettingsScreen.routeName),
            ),
          ),
        ],
      ),
    );
  }
}

/// Loads a home section's items the way the mobile home screen does and hands
/// them to [builder]; shows [placeholder] while loading or on failure.
class _SectionItems extends ConsumerWidget {
  const _SectionItems({required this.section, required this.builder, required this.placeholderHeight});

  final HomeScreenSectionConfiguration section;
  final Widget Function(
    BuildContext context,
    FinampDisplayable<FinampPlayable> displayable,
    List<FinampDisplayableOrPlayable> items,
  )
  builder;
  final double placeholderHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = DesktopThemeScope.of(context);
    Widget message(String text) => SizedBox(
      height: min(placeholderHeight, 80),
      child: Center(child: Text(text, style: p.caption)),
    );
    Widget loading() => _Skeleton(height: placeholderHeight);

    final resolved = ref.watch(resolveSectionProvider(section));
    if (resolved.isLoading) return loading();
    if (resolved.hasError || resolved.value == null) return message(context.l10n.failedToLoadSection);
    final displayable = resolved.value!;
    if (displayable is UnavailableHomeSectionPlayable) return message(context.l10n.notAvailableInOfflineMode);

    final page = ref.watch(pagedContentProvider(displayable));
    final items = page.items;
    if (items == null) {
      if (page.error != null) return message(context.l10n.errorLoadingItems);
      if (!page.isLoading) {
        Future.microtask(() => ref.read(pagedContentProvider(displayable).notifier).fetchHomeScreenItems());
      }
      return loading();
    }
    if (items.isEmpty) return message(context.l10n.desktopStyleNothingHere);
    return builder(context, displayable, items);
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(DesktopMetrics.radiusCard)),
    );
  }
}

/// Scrolls a horizontal list by most of its visible width.
void _page(ScrollController controller, int direction) {
  if (!controller.hasClients) return;
  final position = controller.position;
  final target = (position.pixels + direction * position.viewportDimension * 0.85).clamp(
    position.minScrollExtent,
    position.maxScrollExtent,
  );
  controller.animateTo(target, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
}

// ---------------------------------------------------------------------------
// Featured carousel
// ---------------------------------------------------------------------------

class DesktopFeaturedCarousel extends ConsumerStatefulWidget {
  const DesktopFeaturedCarousel({super.key});

  static const double height = 340;

  @override
  ConsumerState<DesktopFeaturedCarousel> createState() => _DesktopFeaturedCarouselState();
}

class _DesktopFeaturedCarouselState extends ConsumerState<DesktopFeaturedCarousel> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _newPicks() {
    final displayable = ref.read(resolveSectionProvider(desktopFeaturedSection)).value;
    if (displayable != null) ref.read(pagedContentProvider(displayable).notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: l10n.desktopStyleFeatured,
      container: true,
      child: Stack(
        children: [
          _SectionItems(
            section: desktopFeaturedSection,
            placeholderHeight: DesktopFeaturedCarousel.height,
            builder: (context, displayable, items) {
              final albums = [
                for (final i in items)
                  if (i is FinampPlayableDto) i.item,
              ];
              return LayoutBuilder(
                builder: (context, constraints) {
                  const gap = DesktopMetrics.shelfGap;
                  final count = (constraints.maxWidth / 250).floor().clamp(2, 6);
                  final width = (constraints.maxWidth - gap * (count - 1)) / count;
                  return SizedBox(
                    height: DesktopFeaturedCarousel.height,
                    child: ListView.separated(
                      controller: _controller,
                      scrollDirection: Axis.horizontal,
                      itemCount: albums.length,
                      separatorBuilder: (_, _) => const SizedBox(width: gap),
                      itemBuilder: (context, index) => SizedBox(
                        width: width,
                        child: DesktopFeaturedCard(item: albums[index], source: displayable.source),
                      ),
                    ),
                  );
                },
              );
            },
          ),
          // Paging controls float over the carousel's corner, Feishin-style.
          Positioned(
            right: 10,
            bottom: 10,
            child: Row(
              children: [
                DesktopCircleButton(
                  icon: TablerIcons.arrows_shuffle,
                  iconSize: 15,
                  tooltip: l10n.desktopStyleShuffleFeatured,
                  color: Colors.black.withValues(alpha: 0.35),
                  iconColor: Colors.white,
                  onPressed: _newPicks,
                ),
                const SizedBox(width: 6),
                DesktopCircleButton(
                  icon: Icons.chevron_left_rounded,
                  tooltip: l10n.desktopStylePrevious,
                  color: Colors.black.withValues(alpha: 0.35),
                  iconColor: Colors.white,
                  onPressed: () => _page(_controller, -1),
                ),
                const SizedBox(width: 6),
                DesktopCircleButton(
                  icon: Icons.chevron_right_rounded,
                  tooltip: l10n.desktopStyleNext,
                  color: Colors.black.withValues(alpha: 0.35),
                  iconColor: Colors.white,
                  onPressed: () => _page(_controller, 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A tall album card on a gradient of the album's own colour: title on top,
/// the cover in the middle, artist, year and genres underneath.
class DesktopFeaturedCard extends ConsumerStatefulWidget {
  const DesktopFeaturedCard({super.key, required this.item, this.source});

  final BaseItemDto item;
  final QueueItemSource? source;

  @override
  ConsumerState<DesktopFeaturedCard> createState() => _DesktopFeaturedCardState();
}

class _DesktopFeaturedCardState extends ConsumerState<DesktopFeaturedCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final item = widget.item;
    final scheme = ref.watch(finampThemeProvider(ThemeInfo(item)));
    final base = p.isDark ? Color.lerp(scheme.primary, Colors.black, 0.45)! : scheme.primaryContainer;
    final onBase = p.isDark ? Colors.white : scheme.onPrimaryContainer;
    final meta = [
      if (item.productionYear != null) "${item.productionYear}",
      ...?item.genres?.take(2).map((g) => g.toUpperCase()),
    ];
    final radius = BorderRadius.circular(DesktopMetrics.radiusCard);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => Navigator.of(context).pushNamed(AlbumScreen.routeName, arguments: item),
        onSecondaryTap: () => openItemMenu(context: context, item: item),
        child: AnimatedContainer(
          duration: p.motion(const Duration(milliseconds: 400)),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: p.panelBorder),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.lerp(base, Colors.white, _hover && !p.reduceEffects ? 0.06 : 0)!,
                Color.lerp(base, p.isDark ? Colors.black : Colors.white, 0.35)!,
              ],
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: Center(
                  child: Text(
                    item.name ?? "",
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: p.body.copyWith(color: onBase, fontSize: 15, fontWeight: FontWeight.w700, height: 1.25),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Center(
                  child: AnimatedScale(
                    scale: _hover && !p.reduceEffects ? 1.04 : 1,
                    duration: p.motion(const Duration(milliseconds: 200)),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(DesktopMetrics.radiusArtSmall),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: AlbumImage(
                          item: item,
                          borderRadius: BorderRadius.circular(DesktopMetrics.radiusArtSmall),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                item.albumArtist ?? item.artists?.join(", ") ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: p.body.copyWith(color: onBase.withValues(alpha: 0.9)),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 14,
                child: Text(
                  meta.join("   "),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.overline.copyWith(color: onBase.withValues(alpha: 0.7), fontSize: 10),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Genres
// ---------------------------------------------------------------------------

class DesktopGenreGrid extends StatelessWidget {
  const DesktopGenreGrid({super.key});

  static const _maxGenres = 14;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopSectionHeader(title: context.l10n.genres),
        const SizedBox(height: DesktopMetrics.sectionHeaderGap),
        _SectionItems(
          section: desktopGenresSection,
          placeholderHeight: 100,
          builder: (context, _, items) {
            final genres = [
              for (final i in items)
                if (i is FinampPlayableDto) i.item,
            ].take(_maxGenres).toList();
            return LayoutBuilder(
              builder: (context, constraints) {
                const gap = 10.0;
                final columns = (constraints.maxWidth / 190).floor().clamp(2, 8);
                final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final genre in genres)
                      SizedBox(
                        width: width,
                        child: DesktopGenreTile(genre: genre),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }
}

/// A genre as a flat tile with a coloured edge, the colour derived from its
/// name so it stays the same from one visit to the next.
class DesktopGenreTile extends StatelessWidget {
  const DesktopGenreTile({super.key, required this.genre});

  final BaseItemDto genre;

  static Color colorFor(String name) {
    final hue = (name.toLowerCase().codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff) % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.65, 0.55).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final name = genre.name ?? "";
    return Material(
      color: p.surface,
      borderRadius: BorderRadius.circular(DesktopMetrics.radiusControl),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        hoverColor: p.surfaceHover,
        onTap: () => Navigator.of(context).pushNamed(GenreScreen.routeName, arguments: genre),
        onSecondaryTap: () => openItemMenu(context: context, item: genre),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: colorFor(name), width: 4)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.body),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shelves
// ---------------------------------------------------------------------------

/// One configured home section as a horizontal shelf with a header: title,
/// play / shuffle, and paging arrows.
class DesktopShelf extends ConsumerStatefulWidget {
  const DesktopShelf({super.key, required this.section});

  final HomeScreenSectionConfiguration section;

  @override
  ConsumerState<DesktopShelf> createState() => _DesktopShelfState();
}

class _DesktopShelfState extends ConsumerState<DesktopShelf> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _play({required bool shuffle}) async {
    final displayable = ref.read(resolveSectionProvider(widget.section)).value;
    if (displayable is! FinampPlayable) return;
    final playable = displayable as FinampPlayable;
    final slice = await ref.read(getPlayableSliceProvider(item: playable, startingOffset: 0).future);
    await GetIt.instance<QueueService>().startSlicePlayback(shuffle ? slice.shuffle() : slice);
  }

  void _showAll() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<MusicScreen>(builder: (context) => MusicScreen(singleTabConfig: widget.section)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final section = widget.section;
    final displayable = ref.watch(resolveSectionProvider(section)).value;
    final playable = displayable is FinampPlayable;
    final height = calculateItemCollectionCardHeight(
      ref: ref,
      sectionInfo: section,
      itemType: null,
      forHomeScreen: true,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopSectionHeader(
          title: section.getTitle(l10n),
          onTitleTap: _showAll,
          showPaging: true,
          previousTooltip: l10n.desktopStylePrevious,
          nextTooltip: l10n.desktopStyleNext,
          onPrevious: () => _page(_controller, -1),
          onNext: () => _page(_controller, 1),
          actions: [
            if (playable) ...[
              DesktopCircleButton(
                icon: TablerIcons.player_play,
                iconSize: 15,
                filled: false,
                tooltip: l10n.playButtonLabel,
                onPressed: () => _play(shuffle: false),
              ),
              if (section.sortConfig.sortBy != SortBy.random)
                DesktopCircleButton(
                  icon: TablerIcons.arrows_shuffle,
                  iconSize: 15,
                  filled: false,
                  tooltip: l10n.shuffleButtonLabel,
                  onPressed: () => _play(shuffle: true),
                ),
            ],
            TextButton(onPressed: _showAll, child: Text(l10n.showAll)),
          ],
        ),
        const SizedBox(height: DesktopMetrics.sectionHeaderGap),
        _SectionItems(
          section: section,
          placeholderHeight: height,
          builder: (context, displayable, items) => SizedBox(
            height: height,
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: DesktopMetrics.shelfGap - 4),
              itemBuilder: (context, index) => switch (items[index]) {
                FinampPlayableDto item => ItemWrapper(
                  key: ValueKey(item.item.id),
                  item: item.item,
                  isGrid: true,
                  forHomeScreen: true,
                  source: displayable.source,
                ),
                PlayableQueue queue => HomeScreenQueueTile(key: ValueKey(queue.queue.creation), info: queue.queue),
                _ => const SizedBox.shrink(),
              },
            ),
          ),
        ),
      ],
    );
  }
}
