import 'package:diapason/components/MusicScreen/music_screen_tab_view.dart';
import 'package:diapason/components/MusicScreen/sort_and_filter_row.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_models.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class DesktopSearchResults extends ConsumerStatefulWidget {
  const DesktopSearchResults({super.key, required this.query});

  final String query;

  @override
  ConsumerState<DesktopSearchResults> createState() => _DesktopSearchResultsState();
}

class _DesktopSearchResultsState extends ConsumerState<DesktopSearchResults> {
  static const _tabs = [
    (ContentType.albums, "Albums", TablerIcons.disc),
    (ContentType.performingArtists, "Artists", TablerIcons.users),
    (ContentType.tracks, "Songs", TablerIcons.music),
    (ContentType.playlists, "Playlists", TablerIcons.playlist),
  ];

  final Map<ContentType, SortAndFilterController> _controllers = {};
  ContentType _active = ContentType.albums;

  QueueItemSource get _source => QueueItemSource.rawId(
    type: QueueItemSourceType.allTracks,
    name: const QueueItemSourceName(type: QueueItemSourceNameType.shuffleAll),
    id: "shuffleAll",
  );

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Text(
            'Results for "${widget.query}"',
            style: TextStyle(color: p.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              for (final tab in _tabs) _segment(p, tab.$1, tab.$2, tab.$3),
            ],
          ),
        ),
        Expanded(child: _results(_active)),
      ],
    );
  }

  Widget _segment(DesktopPalette p, ContentType type, String label, IconData icon) {
    final active = _active == type;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? p.accentMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: p.surface,
          onTap: () => setState(() => _active = type),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Icon(icon, size: 16, color: active ? p.accent : p.textSecondary),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: active ? p.accent : p.textSecondary,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _results(ContentType tab) {
    final controller = _controllers[tab] ??= SortAndFilterController.trackSettings(tab);
    final sortConfig = ref.watch(resolveSortProvider(controller)).copyWithSearch(widget.query);
    final displayable = MusicScreenPlayable(
      tab: tab,
      library: currentLibraryPlaceholder,
      source: _source,
      sortConfig: sortConfig,
    );
    return Material(
      key: ValueKey("${tab.name}:${widget.query}"),
      type: MaterialType.transparency,
      child: MusicScreenTabView(displayable: displayable),
    );
  }
}
