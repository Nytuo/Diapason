import 'dart:async';

import 'package:diapason/components/album_image.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/library_shortcut.dart';
import 'package:diapason/models/music_models.dart';
import 'package:diapason/screens/desktop/desktop_nav.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/shortcuts/shortcut_service.dart';
import 'package:diapason/components/MusicScreen/sort_and_filter_row.dart';
import 'package:diapason/services/music_screen_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// What the palette can ask the desktop shell to do.
class DesktopPaletteActions {
  const DesktopPaletteActions({
    required this.onGo,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenPlaylist,
    required this.onSearchAll,
  });

  final ValueChanged<DesktopNav> onGo;
  final ValueChanged<BaseItemDto> onOpenAlbum;
  final ValueChanged<BaseItemDto> onOpenArtist;
  final ValueChanged<BaseItemDto> onOpenPlaylist;
  final ValueChanged<String> onSearchAll;
}

/// Spotlight-style command palette: type to filter commands and library items,
/// ↑/↓ to move, Enter to run, Shift+Enter for the full results page, Esc to close.
Future<void> showDesktopCommandPalette(
  BuildContext context, {
  required DesktopPaletteActions actions,
  required DesktopPalette palette,
  required ThemeData theme,
  String initialQuery = "",

  /// Receives the palette text as it is typed, and null when the palette closed by running an
  /// item (which already navigated). Applied by the caller once the palette is gone: updating the
  /// page behind a live palette rebuilds it and steals keyboard focus.
  required ValueNotifier<String?> result,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: "Close search",
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 120),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(animation), child: child),
    ),
    // The dialog lives in the root overlay, outside the shell's (album-art) theme, so re-apply both.
    pageBuilder: (context, _, _) => Theme(
      data: theme,
      child: DesktopThemeScope(
        palette: palette,
        child: _CommandPalette(actions: actions, initialQuery: initialQuery, result: result),
      ),
    ),
  );
}

class _Entry {
  _Entry({
    required this.section,
    required this.title,
    required this.run,
    this.subtitle,
    this.icon,
    this.item,
    this.hint = "Open",
    this.keepOpen = false,
  });

  final String section;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final BaseItemDto? item;
  final String hint;
  final bool keepOpen;
  final void Function() run;
}

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette({required this.actions, required this.initialQuery, required this.result});

  final ValueNotifier<String?> result;

  final DesktopPaletteActions actions;
  final String initialQuery;

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialQuery);
  final _focus = FocusNode();
  final _rowKeys = <int, GlobalKey>{};
  Timer? _debounce;
  @override
  void initState() {
    super.initState();
    widget.result.value = widget.initialQuery;
  }

  late String _debounced = widget.initialQuery.trim();
  int _selected = 0;

  static const _limit = 4;
  static const _sections = [
    (ContentType.tracks, "Songs", "Play"),
    (ContentType.albums, "Albums", "Open"),
    (ContentType.performingArtists, "Artists", "Open"),
    (ContentType.playlists, "Playlists", "Open"),
  ];

  QueueItemSource get _source => QueueItemSource.rawId(
    type: QueueItemSourceType.allTracks,
    name: const QueueItemSourceName(type: QueueItemSourceNameType.shuffleAll),
    id: "shuffleAll",
  );

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    widget.result.value = value.trim();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() {
          _debounced = value.trim();
          _selected = 0;
        });
      }
    });
    // Empty field: show the idle state straight away, no waiting.
    if (value.trim().isEmpty) {
      setState(() {
        _debounced = "";
        _selected = 0;
      });
    }
  }

  void _close() => Navigator.of(context).pop();

  void _closeThen(void Function() action) {
    widget.result.value = null;
    Navigator.of(context).pop();
    action();
  }

  static (ContentType?, String) _parse(String raw) => parseSearchQuery(raw);

  void _setText(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _onChanged(text);
    _focus.requestFocus();
  }

  List<_Entry> _buildEntries() {
    final a = widget.actions;
    final (typeFilter, q) = _parse(_debounced);
    final entries = <_Entry>[];
    final rawEmpty = _debounced.isEmpty;

    final navMatches = typeFilter != null
        ? const <DesktopNav>[]
        : DesktopNav.values.where((n) => q.isEmpty || n.label.toLowerCase().contains(q.toLowerCase()));

    if (typeFilter != null && q.isEmpty) {
      return entries; // waiting for the term; the empty state explains.
    }

    if (rawEmpty) {
      for (final (prefix, label, icon) in const [
        ("song:", "Songs", TablerIcons.music),
        ("album:", "Albums", TablerIcons.disc),
        ("artist:", "Artists", TablerIcons.users),
        ("playlist:", "Playlists", TablerIcons.playlist),
      ]) {
        entries.add(
          _Entry(
            section: "Search by type",
            title: "$prefix  search $label only",
            icon: icon,
            hint: "Use",
            keepOpen: true,
            run: () => _setText("$prefix "),
          ),
        );
      }
    }

    if (rawEmpty) {
      final recents = GetIt.instance.isRegistered<ShortcutService>()
          ? GetIt.instance<ShortcutService>().recentSearches.take(5)
          : const <SearchHistoryEntry>[];
      for (final r in recents) {
        entries.add(
          _Entry(
            section: "Recent searches",
            title: r.query,
            icon: TablerIcons.history,
            hint: "Search",
            keepOpen: true,
            run: () {
              _controller.value = TextEditingValue(
                text: r.query,
                selection: TextSelection.collapsed(offset: r.query.length),
              );
              _onChanged(r.query);
            },
          ),
        );
      }
    }

    for (final n in navMatches) {
      entries.add(
        _Entry(section: "Go to", title: n.label, icon: n.icon, hint: "Go", run: () => _closeThen(() => a.onGo(n))),
      );
    }

    if (q.isNotEmpty) {
      for (final (tab, title, hint) in _sections.where((s) => typeFilter == null || s.$1 == typeFilter)) {
        final request = MusicScreenPlayable(
          tab: tab,
          library: currentLibraryPlaceholder,
          source: _source,
          sortConfig: ResolvedSortConfig.defaultSort.copyWithSearch(q),
        );
        final items =
            ref
                .watch(
                  loadHomeSectionItemsProvider(
                    request: request,
                    startIndex: 0,
                    limit: typeFilter == null ? _limit : 12,
                  ),
                )
                .value ??
            const [];
        for (final item in items) {
          entries.add(
            _Entry(
              section: title,
              title: item.name ?? "Unknown",
              subtitle: _subtitle(tab, item),
              item: item,
              hint: hint,
              run: () => _closeThen(() {
                switch (tab) {
                  case ContentType.tracks:
                    unawaited(
                      GetIt.instance<QueueService>().startPlayback(
                        items: [item],
                        source: QueueItemSource.fromBaseItem(item),
                        order: FinampPlaybackOrder.linear,
                      ),
                    );
                  case ContentType.albums:
                    a.onOpenAlbum(item);
                  case ContentType.playlists:
                    a.onOpenPlaylist(item);
                  default:
                    a.onOpenArtist(item);
                }
              }),
            ),
          );
        }
      }
      entries.add(
        _Entry(
          section: "Everything",
          title: 'See all results for "$q"',
          icon: TablerIcons.search,
          hint: "⇧↵",
          run: () => _closeThen(() => a.onSearchAll(_controller.text.trim())),
        ),
      );
    }
    return entries;
  }

  String? _subtitle(ContentType tab, BaseItemDto item) => switch (tab) {
    ContentType.tracks => [
      if (item.artists?.isNotEmpty ?? false) item.artists!.join(", ") else item.albumArtist,
      item.album,
    ].whereType<String>().join("  ·  "),
    ContentType.albums => item.albumArtist,
    ContentType.playlists => item.childCount == null ? null : "${item.childCount} tracks",
    _ => null,
  };

  KeyEventResult _onKey(FocusNode _, KeyEvent event, List<_Entry> entries) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      if (entries.isEmpty) return KeyEventResult.handled;
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() => _selected = (_selected + delta) % entries.length);
      if (_selected < 0) setState(() => _selected = entries.length - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _rowKeys[_selected]?.currentContext;
        if (ctx != null) unawaited(Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 80)));
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final q = _controller.text.trim();
      if (HardwareKeyboard.instance.isShiftPressed && q.isNotEmpty) {
        _closeThen(() => widget.actions.onSearchAll(q));
      } else if (entries.isNotEmpty) {
        entries[_selected.clamp(0, entries.length - 1)].run();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final entries = _buildEntries();
    if (_selected >= entries.length) _selected = entries.isEmpty ? 0 : entries.length - 1;
    final searching = _debounced.isNotEmpty;
    final (activeFilter, activeTerm) = _parse(_debounced);
    final waitingForTerm = activeFilter != null && activeTerm.isEmpty;

    return Align(
      alignment: const Alignment(0, -0.55),
      child: Material(
        color: p.bgSecondary,
        elevation: 24,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 640,
            // Fixed height: the palette must not grow/shrink while results change.
            minHeight: 480,
            maxHeight: 480,
          ),
          child: Focus(
            onKeyEvent: (node, event) => _onKey(node, event, entries),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Icon(TablerIcons.search, size: 18, color: p.textTertiary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          autofocus: true,
                          onChanged: _onChanged,
                          style: TextStyle(color: p.textPrimary, fontSize: 16),
                          cursorColor: p.accent,
                          decoration: InputDecoration(
                            hintText: "Search, jump to a page, or filter with  song:  album:  artist:  playlist:",
                            hintStyle: TextStyle(color: p.textTertiary, fontSize: 15),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      if (_controller.text.isNotEmpty)
                        IconButton(
                          tooltip: "Clear",
                          iconSize: 16,
                          color: p.textTertiary,
                          icon: const Icon(TablerIcons.x),
                          onPressed: () {
                            _controller.clear();
                            _onChanged("");
                            _focus.requestFocus();
                          },
                        ),
                    ],
                  ),
                ),
                Divider(height: 1, color: p.borderSubtle),
                Expanded(
                  child: entries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            waitingForTerm
                                ? "Type a search term after the colon"
                                : searching
                                ? 'No matches for "$activeTerm"'
                                : "Start typing to search",
                            style: TextStyle(color: p.textSecondary),
                          ),
                        )
                      : ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: _rows(p, entries)),
                ),
                Divider(height: 1, color: p.borderSubtle),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      for (final (k, label) in const [
                        ("↑↓", "navigate"),
                        ("↵", "select"),
                        ("⇧↵", "all results"),
                        ("esc", "close"),
                      ]) ...[
                        _KeyCap(k),
                        const SizedBox(width: 6),
                        Text(label, style: TextStyle(color: p.textTertiary, fontSize: 11)),
                        const SizedBox(width: 16),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _rows(DesktopPalette p, List<_Entry> entries) {
    final rows = <Widget>[];
    String? lastSection;
    for (final (i, e) in entries.indexed) {
      if (e.section != lastSection) {
        lastSection = e.section;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              e.section.toUpperCase(),
              style: TextStyle(color: p.textTertiary, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.1),
            ),
          ),
        );
      }
      final selected = i == _selected;
      rows.add(
        KeyedSubtree(
          key: _rowKeys.putIfAbsent(i, GlobalKey.new),
          child: MouseRegion(
            onHover: (_) {
              if (_selected != i) setState(() => _selected = i);
            },
            child: InkWell(
              onTap: e.run,
              child: Container(
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: selected ? p.accentMuted : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: e.item != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(5),
                              child: AlbumImage(item: e.item),
                            )
                          : Icon(e.icon, size: 18, color: selected ? p.accent : p.textSecondary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected ? p.accent : p.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (e.subtitle != null && e.subtitle!.isNotEmpty)
                            Text(
                              e.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.textSecondary, fontSize: 11.5),
                            ),
                        ],
                      ),
                    ),
                    if (selected) Text(e.hint, style: TextStyle(color: p.textSecondary, fontSize: 11.5)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return rows;
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: p.border),
      ),
      child: Text(
        label,
        style: TextStyle(color: p.textSecondary, fontSize: 10.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Splits "song: foo" into (type filter, "foo"). Unknown prefixes are left as plain text.
(ContentType?, String) parseSearchQuery(String raw) {
  final match = RegExp(r'^\s*([a-zA-Z]+)\s*:\s*(.*)$').firstMatch(raw);
  if (match != null) {
    final tab = _searchTypeAliases[match.group(1)!.toLowerCase()];
    if (tab != null) return (tab, match.group(2)!.trim());
  }
  return (null, raw.trim());
}

const _searchTypeAliases = {
  "song": ContentType.tracks,
  "songs": ContentType.tracks,
  "track": ContentType.tracks,
  "tracks": ContentType.tracks,
  "album": ContentType.albums,
  "albums": ContentType.albums,
  "artist": ContentType.performingArtists,
  "artists": ContentType.performingArtists,
  "playlist": ContentType.playlists,
  "playlists": ContentType.playlists,
};
