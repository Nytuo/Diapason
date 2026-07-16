import 'package:diapason/components/AddToPlaylistScreen/new_playlist_dialog.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/desktop/desktop_app_menu.dart';
import 'package:diapason/screens/desktop/desktop_nav.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/queue_service.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:window_manager/window_manager.dart';

final desktopPlaylistsProvider = FutureProvider.autoDispose<List<BaseItemDto>>((ref) async {
  return GetIt.instance<AggregateBackend>().getItems(
    includeItemTypes: ContentType.playlists.itemType?.jellyfinName,
    sortBy: "SortName",
    sortOrder: "Ascending",
  );
});

class DesktopSidebar extends ConsumerStatefulWidget {
  const DesktopSidebar({
    super.key,
    required this.current,
    required this.onSelect,
    required this.onToggleTheme,
    required this.brightness,
    required this.onOpenPlaylist,
    this.openPlaylistId,
  });

  final DesktopNav current;
  final ValueChanged<DesktopNav> onSelect;
  final VoidCallback onToggleTheme;
  final Brightness brightness;

  final ValueChanged<BaseItemDto> onOpenPlaylist;

  final BaseItemId? openPlaylistId;

  @override
  ConsumerState<DesktopSidebar> createState() => _DesktopSidebarState();
}

class _DesktopSidebarState extends ConsumerState<DesktopSidebar> {
  static const _top = [
    DesktopNav.home,
    DesktopNav.albums,
    DesktopNav.artists,
    DesktopNav.songs,
    DesktopNav.genres,
  ];
  static const _bottom = [
    DesktopNav.smart,
    DesktopNav.discover,
    DesktopNav.youtube,
    DesktopNav.folders,
  ];

  bool _playlistsExpanded = true;
  bool _creating = false;

  Future<void> _createPlaylist() async {
    if (_creating) return;
    final result = await showDialog<(Future<BaseItemId>, String?)?>(
      context: context,
      builder: (_) => const NewPlaylistDialog(itemsToAdd: []),
    );
    if (result == null) return;
    setState(() => _creating = true);
    try {
      await result.$1;
      ref.invalidate(desktopPlaylistsProvider);
      if (mounted) setState(() => _playlistsExpanded = true);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(right: BorderSide(color: p.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, p),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
              children: [
                for (final nav in _top) _navButton(context, p, nav),
                _playlistsSection(context, p),
                for (final nav in _bottom) _navButton(context, p, nav),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: _queueButton(context, p),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, DesktopPalette p) {
    final topInset = Platform.isMacOS ? 28.0 : 18.0;
    final header = Container(
      padding: EdgeInsets.fromLTRB(20, topInset, 12, 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Diapason",
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: widget.onToggleTheme,
            tooltip: "Toggle theme",
            iconSize: 18,
            color: p.textTertiary,
            icon: Icon(widget.brightness == Brightness.dark ? TablerIcons.sun : TablerIcons.moon),
          ),
          const DesktopAppMenu(),
        ],
      ),
    );
    return DragToMoveArea(child: header);
  }

  Widget _navButton(BuildContext context, DesktopPalette p, DesktopNav nav) {
    final active = widget.current == nav && widget.openPlaylistId == null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: active ? p.accentMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: p.surface,
          onTap: () => widget.onSelect(nav),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(nav.icon, size: 18, color: active ? p.accent : p.textSecondary),
                const SizedBox(width: 12),
                Text(
                  nav.label,
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

  Widget _playlistsSection(BuildContext context, DesktopPalette p) {
    final active = widget.current == DesktopNav.playlists && widget.openPlaylistId == null;
    final playlists = ref.watch(desktopPlaylistsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Material(
            color: active ? p.accentMuted : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              hoverColor: p.surface,
              onTap: () => widget.onSelect(DesktopNav.playlists),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
                child: Row(
                  children: [
                    Icon(DesktopNav.playlists.icon, size: 18, color: active ? p.accent : p.textSecondary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        DesktopNav.playlists.label,
                        style: TextStyle(
                          color: active ? p.accent : p.textSecondary,
                          fontSize: 13,
                          fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                    _miniIcon(
                      p,
                      _creating ? TablerIcons.loader_2 : TablerIcons.plus,
                      "New playlist",
                      _creating ? null : _createPlaylist,
                    ),
                    _miniIcon(
                      p,
                      _playlistsExpanded ? TablerIcons.chevron_down : TablerIcons.chevron_right,
                      _playlistsExpanded ? "Collapse" : "Expand",
                      () => setState(() => _playlistsExpanded = !_playlistsExpanded),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_playlistsExpanded)
          playlists.when(
            loading: () => _subtleRow(p, "Loading…"),
            error: (e, _) => _subtleRow(p, "Couldn't load playlists"),
            data: (items) => items.isEmpty
                ? _subtleRow(p, "No playlists yet")
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final pl in items) _playlistTile(context, p, pl)],
                  ),
          ),
      ],
    );
  }

  Widget _miniIcon(DesktopPalette p, IconData icon, String tooltip, VoidCallback? onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 15, color: p.textTertiary),
        ),
      ),
    );
  }

  Widget _subtleRow(DesktopPalette p, String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 42, top: 4, bottom: 6),
      child: Text(label, style: TextStyle(color: p.textTertiary, fontSize: 12, fontStyle: FontStyle.italic)),
    );
  }

  Widget _playlistTile(BuildContext context, DesktopPalette p, BaseItemDto pl) {
    final active = widget.openPlaylistId == pl.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: active ? p.accentMuted : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: p.surface,
          onTap: () => widget.onOpenPlaylist(pl),
          child: Padding(
            padding: const EdgeInsets.only(left: 34, top: 7, right: 12, bottom: 7),
            child: Row(
              children: [
                Icon(TablerIcons.music, size: 15, color: active ? p.accent : p.textTertiary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    pl.name ?? "Unknown playlist",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? p.accent : p.textSecondary,
                      fontSize: 12.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _queueButton(BuildContext context, DesktopPalette p) {
    final active = widget.current == DesktopNav.queue;
    final queueService = GetIt.instance<QueueService>();
    return Material(
      color: active ? p.accent : p.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => widget.onSelect(DesktopNav.queue),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Icon(TablerIcons.list_numbers, size: 18, color: active ? p.textInverse : p.textSecondary),
              const SizedBox(width: 12),
              Text(
                "QUEUE",
                style: TextStyle(
                  color: active ? p.textInverse : p.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              StreamBuilder(
                stream: queueService.getQueueStream(),
                builder: (context, snapshot) {
                  final count = queueService.getQueue().nextUp.length + queueService.getQueue().queue.length;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: active ? Colors.white24 : p.bg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      "$count",
                      style: TextStyle(
                        color: active ? p.textInverse : p.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
