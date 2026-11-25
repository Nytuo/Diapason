import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'package:diapason/components/MusicScreen/item_wrapper.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/components/favorite_button.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/desktop/desktop_album_detail.dart';
import 'package:diapason/screens/desktop/desktop_kit.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/services/artist_content_provider.dart';
import 'package:diapason/services/artist_info_service.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/audio_service_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// An artist's page, after Chilpa's: a header band (round portrait, name, bio, round actions), a "Jump to" strip,
/// then Popular Tracks and Albums.
class DesktopArtistDetail extends ConsumerStatefulWidget {
  const DesktopArtistDetail({super.key, required this.artist});

  final BaseItemDto artist;

  @override
  ConsumerState<DesktopArtistDetail> createState() => _DesktopArtistDetailState();
}

class _DesktopArtistDetailState extends ConsumerState<DesktopArtistDetail> {
  final _aboutKey = GlobalKey();
  final _tracksKey = GlobalKey();
  final _albumsKey = GlobalKey();
  bool _bioExpanded = false;
  bool _networkOpen = true;

  BaseItemDto get artist => widget.artist;

  void _jump(GlobalKey key) {
    final context = key.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final albumsAsync = ref.watch(getPerformingArtistAlbumsProvider(artist: artist));
    final albums = albumsAsync.value ?? [];
    final tracks = ref.watch(getArtistTracksSectionProvider(artist: artist)).value?.$1 ?? [];
    // The server's own overview wins; otherwise what the public databases know (Wikipedia via MusicBrainz).
    final info = ref.watch(artistInfoProvider(artist.name ?? "")).value;
    final serverBio = (artist.overview ?? "").trim();
    final bio = serverBio.isNotEmpty ? serverBio : (info?.bio ?? "");

    return Material(
      color: p.bg,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header(context, p, bio, albums.length, info)),
          SliverToBoxAdapter(child: _jumpStrip(p, hasTracks: tracks.isNotEmpty)),
          if (tracks.isNotEmpty || (info != null && !info.isEmpty))
            SliverToBoxAdapter(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Wide windows put the Network panel beside the tracks; narrow ones stack it underneath.
                  final wide = constraints.maxWidth >= 980;
                  final showPanel = info != null && !info.isEmpty && _networkOpen;
                  final trackList = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (tracks.isNotEmpty) ...[
                        _heading(p, "Popular Tracks", key: _tracksKey),
                        for (final (i, track) in tracks.indexed)
                          DesktopTrackRow(
                            item: track,
                            index: i,
                            queue: tracks,
                            source: QueueItemSource.fromBaseItem(artist),
                          ),
                      ],
                    ],
                  );
                  if (!wide) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [trackList, if (showPanel) _networkPanel(context, p, info, wide: false)],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: trackList),
                      if (showPanel) _networkPanel(context, p, info, wide: true),
                    ],
                  );
                },
              ),
            ),
          SliverToBoxAdapter(child: _heading(p, "Albums", key: _albumsKey)),
          if (albumsAsync.isLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.78,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => ItemWrapper(item: albums[index], isGrid: true),
                  childCount: albums.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _heading(DesktopPalette p, String text, {required GlobalKey key}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
    child: Text(
      text,
      style: TextStyle(color: p.textPrimary, fontSize: 22, fontWeight: FontWeight.bold),
    ),
  );

  Widget _header(BuildContext context, DesktopPalette p, String bio, int albumCount, ArtistInfo? info) {
    final serverPortrait = artist.imageTags?["Primary"] != null;
    final portrait = serverPortrait ? null : info?.portraitUrl;
    return DecoratedBox(
      key: _aboutKey,
      decoration: BoxDecoration(
        // A faint veil, like Chilpa's header: never the light "raised surface" colour.
        color: (p.isDark ? Colors.white : Colors.black).withValues(alpha: p.isDark ? 0.05 : 0.04),
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DesktopDetailBackButton(color: p.textSecondary),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 200,
                    height: 200,
                    child: portrait == null
                        ? AlbumImage(item: artist)
                        : Tooltip(
                            message: info?.portraitCredit ?? "Wikimedia Commons",
                            child: _CachedPortrait(
                              url: portrait,
                              fallback: AlbumImage(item: artist),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      Text(
                        artist.name ?? "Unknown",
                        style: TextStyle(
                          color: p.textPrimary,
                          fontSize: 34,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (bio.isNotEmpty) ...[
                        Text(
                          bio,
                          maxLines: _bioExpanded ? null : 3,
                          overflow: _bioExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                          style: TextStyle(color: p.textSecondary, fontSize: 13, height: 1.4),
                        ),
                        if (bio.length > 220)
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => setState(() => _bioExpanded = !_bioExpanded),
                              child: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  _bioExpanded ? "Show less" : "Read more",
                                  style: TextStyle(color: p.accent, fontSize: 13),
                                ),
                              ),
                            ),
                          ),
                      ] else
                        Text("$albumCount albums", style: TextStyle(color: p.textSecondary, fontSize: 14)),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          DesktopCircleButton(
                            icon: TablerIcons.player_play_filled,
                            size: 36,
                            iconSize: 18,
                            color: p.accent,
                            iconColor: p.textInverse,
                            tooltip: "Play mix",
                            onPressed: () => GetIt.instance<AudioServiceHelper>().startInstantMixForArtists([artist]),
                          ),
                          const SizedBox(width: 8),
                          DecoratedBox(
                            decoration: BoxDecoration(color: p.surface, shape: BoxShape.circle),
                            child: FavoriteButton(item: artist, color: p.textSecondary, size: 18),
                          ),
                          const SizedBox(width: 8),
                          DesktopCircleButton(
                            icon: TablerIcons.dots,
                            size: 36,
                            iconSize: 18,
                            tooltip: "More",
                            onPressed: () => openItemMenu(context: context, item: artist),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSimilar(String name) async {
    try {
      final found = await GetIt.instance<AggregateBackend>().getItems(
        includeItemTypes: "MusicArtist",
        searchTerm: name,
        limit: 5,
      );
      final match = found.where((a) => (a.name ?? "").toLowerCase() == name.toLowerCase()).firstOrNull;
      if (match == null) {
        GlobalSnackbar.message((c) => "$name is not in your library", isConfirmation: false);
        return;
      }
      if (mounted) unawaited(DesktopRouter.pushNamed(context, ArtistScreen.routeName, arguments: match));
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }

  static const _months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  /// "1975-12-25" -> "25 Dec 1975"; partial dates keep what they have.
  static String _date(String raw) {
    final parts = raw.split("-");
    final month = parts.length > 1 ? int.tryParse(parts[1]) : null;
    final day = parts.length > 2 ? int.tryParse(parts[2]) : null;
    return [
      if (day != null) "$day",
      if (month != null && month >= 1 && month <= 12) _months[month - 1],
      parts.first,
    ].join(" ");
  }

  /// Facts, labels, members and similar artists from the public databases: Chilpa's "Network" panel.
  Widget _networkPanel(BuildContext context, DesktopPalette p, ArtistInfo info, {required bool wide}) {
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(color: p.textTertiary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2),
      ),
    );
    Widget fact(String name, String value, {bool accent = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            name.toUpperCase(),
            style: TextStyle(color: p.textTertiary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: accent ? p.accent : p.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
    Widget row(String text, IconData icon, {VoidCallback? onTap}) => MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Icon(icon, size: 14, color: p.textTertiary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: onTap == null ? p.textSecondary : p.textPrimary, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final born = info.type == "Person";
    // Beside the tracks the body scrolls inside the capped panel; stacked underneath it just grows.
    Widget scrollable(Widget child) => wide ? Flexible(child: SingleChildScrollView(child: child)) : child;
    return Container(
      width: wide ? 320 : null,
      // Beside the tracks the panel is capped and scrolls inside, so a long list doesn't stretch the page.
      constraints: wide ? const BoxConstraints(maxHeight: 420) : null,
      margin: wide ? const EdgeInsets.fromLTRB(8, 24, 24, 16) : const EdgeInsets.fromLTRB(24, 16, 24, 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
      decoration: BoxDecoration(
        color: (p.isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(DesktopMetrics.radiusPanel),
        border: Border.all(color: p.panelBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "Network",
                  style: TextStyle(color: p.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                color: p.textSecondary,
                tooltip: "Close",
                icon: const Icon(TablerIcons.x),
                onPressed: () => setState(() => _networkOpen = false),
              ),
            ],
          ),
          Divider(height: 8, color: p.borderSubtle),
          scrollable(
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6),
                  if (info.begin != null) fact(born ? "Born" : "Founded", _date(info.begin!)),
                  if (info.end != null) fact(born ? "Died" : "Ended", _date(info.end!)),
                  if (info.place != null) fact(born ? "Born in" : "Founded in", info.place!, accent: true),
                  if (info.tags.isNotEmpty) ...[
                    label("Tags"),
                    Text(info.tags.join("  ·  "), style: TextStyle(color: p.textSecondary, fontSize: 13)),
                  ],
                  if (info.labels.isNotEmpty) ...[
                    label("Labels"),
                    for (final l in info.labels) row(l, TablerIcons.disc),
                  ],
                  if (info.members.isNotEmpty) ...[
                    label("Members"),
                    for (final m in info.members) row(m, TablerIcons.user, onTap: () => _openSimilar(m)),
                  ],
                  if (info.similar.isNotEmpty) ...[
                    label("Similar artists"),
                    for (final a in info.similar) row(a, TablerIcons.user, onTap: () => _openSimilar(a)),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    [
                      "Data from MusicBrainz, Wikipedia and ListenBrainz",
                      if (info.portraitCredit != null && info.portraitCredit!.isNotEmpty)
                        "Portrait: ${info.portraitCredit}",
                    ].join(" · "),
                    style: TextStyle(color: p.textTertiary, fontSize: 10.5, height: 1.3),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The "JUMP TO" strip under the header.
  Widget _jumpStrip(DesktopPalette p, {required bool hasTracks}) {
    Widget link(String text, GlobalKey key) => Padding(
      padding: const EdgeInsets.only(right: 20),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _jump(key),
          child: Text(text, style: TextStyle(color: p.textPrimary, fontSize: 13)),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Text(
              "JUMP TO",
              style: TextStyle(color: p.textTertiary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2),
            ),
          ),
          link("About", _aboutKey),
          if (hasTracks) link("Popular Tracks", _tracksKey),
          link("Albums", _albumsKey),
        ],
      ),
    );
  }
}

/// A portrait from the web, kept in the app's file cache so it is fetched once.
class _CachedPortrait extends StatelessWidget {
  const _CachedPortrait({required this.url, required this.fallback});

  final String url;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File>(
      future: DefaultCacheManager().getSingleFile(url),
      builder: (context, snapshot) {
        if (snapshot.hasError) return fallback;
        final file = snapshot.data;
        if (file == null) return fallback;
        return Image.file(file, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
      },
    );
  }
}
