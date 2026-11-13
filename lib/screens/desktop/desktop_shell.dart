import 'dart:async';

import 'package:diapason/components/YtDlp/youtube_setup_view.dart';
import 'package:diapason/components/update_dialog.dart';
import 'package:diapason/screens/analytics_settings_screen.dart';
import 'package:diapason/services/updater_prefs.dart';
import 'package:diapason/screens/desktop/desktop_command_palette.dart';
import 'package:diapason/services/shortcuts/shortcut_service.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:diapason/screens/desktop/desktop_content.dart';
import 'package:diapason/screens/desktop/desktop_fullscreen_player.dart';
import 'package:diapason/screens/desktop/desktop_header_bar.dart';
import 'package:diapason/screens/desktop/desktop_mini_player.dart';
import 'package:diapason/screens/desktop/desktop_nav.dart';
import 'package:diapason/screens/desktop/desktop_player_bar.dart';
import 'package:diapason/screens/desktop/desktop_sidebar.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/lyrics_screen.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  static const routeName = "/desktop";

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  DesktopNav _nav = DesktopNav.home;
  String _searchQuery = "";
  BaseItemDto? _openPlaylist;
  BaseItemDto? _detailItem;
  bool _detailIsArtist = false;
  bool _lyricsOpen = false;
  bool _fullscreen = false;
  DesktopPalette? _palette;
  ThemeData? _themeData;
  bool _miniMode = false;
  Size? _restoreSize;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(AnalyticsConsentDialog.showIfNeeded(context));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) unawaited(offerYtDlpSetupIfNeeded(context));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Respect the "check automatically" toggle in Settings → Updates.
      if (!await UpdaterPrefs.isAutoCheckEnabled()) return;
      if (mounted) await checkForUpdatesInteractive(context);
    });
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyK) return false;
    final kb = HardwareKeyboard.instance;
    if (!(kb.isMetaPressed || kb.isControlPressed) || !mounted) return false;
    // Only when the shell itself is on top (not Settings, a dialog, ...).
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    _openPalette();
    return true;
  }

  void _openPalette() {
    final result = ValueNotifier<String?>(_searchQuery);
    unawaited(
      showDesktopCommandPalette(
        context,
        result: result,
        palette: _palette ?? DesktopPalette.fromScheme(Theme.of(context).colorScheme),
        theme: _themeData ?? Theme.of(context),
        initialQuery: _searchQuery,
        actions: DesktopPaletteActions(
          onGo: _select,
          onOpenAlbum: (item) => _openDetail(item, isArtist: false),
          onOpenArtist: (item) => _openDetail(item, isArtist: true),
          onOpenPlaylist: _openPlaylistDetail,
          onSearchAll: (q) {
            if (GetIt.instance.isRegistered<ShortcutService>()) {
              unawaited(GetIt.instance<ShortcutService>().recordSearch(q));
            }
            setState(() => _searchQuery = q);
          },
        ),
      ).then((_) {
        // Only now, with the palette gone, show what was typed in the header / results behind it.
        final typed = result.value;
        if (mounted && typed != null && typed != _searchQuery) setState(() => _searchQuery = typed);
        result.dispose();
      }),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  void _select(DesktopNav nav) {
    if (nav == _nav && _openPlaylist == null && _detailItem == null) return;
    setState(() {
      _nav = nav;
      _openPlaylist = null;
      _detailItem = null;
      _searchQuery = "";
    });
  }

  void _openPlaylistDetail(BaseItemDto playlist) {
    setState(() {
      _nav = DesktopNav.playlists;
      _openPlaylist = playlist;
      _detailItem = null;
      _searchQuery = "";
    });
  }

  /// Opens an already-resolved album or artist as a detail page over the
  /// current tab — used by the player bar's "go to album/artist" actions.
  void _openDetail(BaseItemDto item, {required bool isArtist}) {
    setState(() {
      _openPlaylist = null;
      _detailItem = item;
      _detailIsArtist = isArtist;
      _searchQuery = "";
    });
  }

  Future<void> _enterMiniMode() async {
    try {
      _restoreSize = await windowManager.getSize();
      await windowManager.setMinimumSize(const Size(300, 420));
      await windowManager.setSize(const Size(340, 520));
      await windowManager.setAlwaysOnTop(true);
    } catch (_) {}
    if (mounted) setState(() => _miniMode = true);
  }

  Future<void> _exitMiniMode() async {
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setMinimumSize(const Size(400, 500));
      if (_restoreSize != null) await windowManager.setSize(_restoreSize!);
    } catch (_) {}
    if (mounted) setState(() => _miniMode = false);
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    try {
      await windowManager.setFullScreen(next);
    } catch (_) {}
    if (mounted) setState(() => _fullscreen = next);
  }

  @override
  Widget build(BuildContext context) {
    return PlayerScreenTheme(
      themeTransitionDuration: Duration.zero,
      child: Builder(
        builder: (context) {
          final palette = DesktopPalette.fromScheme(Theme.of(context).colorScheme);
          _palette = palette;
          _themeData = Theme.of(context);
          return DesktopThemeScope(
            palette: palette,
            child: Scaffold(backgroundColor: palette.bg, body: _body(palette)),
          );
        },
      ),
    );
  }

  Widget _body(DesktopPalette palette) {
    if (_miniMode) {
      return DesktopMiniPlayer(onExit: _exitMiniMode);
    }
    if (_fullscreen) {
      return DesktopFullscreenPlayer(onExit: _toggleFullscreen);
    }
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Consumer(
                builder: (context, ref, _) {
                  final mode = ref.watch(finampSettingsProvider.themeMode);
                  return DesktopSidebar(
                    current: _nav,
                    onSelect: _select,
                    onOpenPlaylist: _openPlaylistDetail,
                    openPlaylistId: _openPlaylist?.id,
                    brightness: palette.brightness,
                    onToggleTheme: () =>
                        FinampSetters.setThemeMode(mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark),
                  );
                },
              ),
              Expanded(
                child: Column(
                  children: [
                    DesktopHeaderBar(
                      title: _nav.label,
                      query: _searchQuery,
                      onOpenSearch: _openPalette,
                      onClearSearch: () => setState(() => _searchQuery = ""),
                    ),
                    Expanded(
                      child: DesktopSearchScope(
                        query: parseSearchQuery(_searchQuery).$2,
                        type: parseSearchQuery(_searchQuery).$1,
                        child: DesktopContent(
                          nav: _nav,
                          openItem: _openPlaylist,
                          detailItem: _detailItem,
                          detailIsArtist: _detailIsArtist,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_lyricsOpen)
                Container(
                  width: 360,
                  decoration: BoxDecoration(
                    color: palette.bgSecondary,
                    border: Border(left: BorderSide(color: palette.borderSubtle)),
                  ),
                  child: Column(
                    children: [
                      _lyricsHeader(palette),
                      const Expanded(child: LyricsView()),
                    ],
                  ),
                ),
            ],
          ),
        ),
        DesktopPlayerBar(
          lyricsOpen: _lyricsOpen,
          onToggleLyrics: () => setState(() => _lyricsOpen = !_lyricsOpen),
          onMiniPlayer: _enterMiniMode,
          onFullscreen: _toggleFullscreen,
          onOpenLibraryItem: _openDetail,
        ),
      ],
    );
  }

  Widget _lyricsHeader(DesktopPalette palette) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
      ),
      child: Row(
        children: [
          Text(
            "Lyrics",
            style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          IconButton(
            iconSize: 18,
            color: palette.textSecondary,
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _lyricsOpen = false),
          ),
        ],
      ),
    );
  }
}
