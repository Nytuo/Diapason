import 'package:diapason/components/update_dialog.dart';
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
  final _searchController = TextEditingController();
  String _searchQuery = "";
  BaseItemDto? _openPlaylist;
  bool _lyricsOpen = false;
  bool _fullscreen = false;
  bool _miniMode = false;
  Size? _restoreSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkForUpdatesInteractive(context);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _select(DesktopNav nav) {
    if (nav == _nav && _openPlaylist == null) return;
    setState(() {
      _nav = nav;
      _openPlaylist = null;
      _searchController.clear();
      _searchQuery = "";
    });
  }

  void _openPlaylistDetail(BaseItemDto playlist) {
    setState(() {
      _nav = DesktopNav.playlists;
      _openPlaylist = playlist;
      _searchController.clear();
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
      themeTransitionDuration: const Duration(milliseconds: 200),
      child: Builder(
        builder: (context) {
          final palette = DesktopPalette.fromScheme(Theme.of(context).colorScheme);
          return DesktopThemeScope(
            palette: palette,
            child: Scaffold(
              backgroundColor: palette.bg,
              body: _body(palette),
            ),
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
                    onToggleTheme: () => FinampSetters.setThemeMode(
                      mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
                    ),
                  );
                },
              ),
              Expanded(
                child: Column(
                  children: [
                    DesktopHeaderBar(
                      title: _nav.label,
                      searchController: _searchController,
                      onSearchChanged: (v) => setState(() => _searchQuery = v),
                    ),
                    Expanded(
                      child: DesktopSearchScope(
                        query: _searchQuery,
                        child: DesktopContent(nav: _nav, openItem: _openPlaylist),
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
        ),
      ],
    );
  }

  Widget _lyricsHeader(DesktopPalette palette) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.borderSubtle))),
      child: Row(
        children: [
          Text("Lyrics", style: TextStyle(color: palette.textPrimary, fontWeight: FontWeight.bold)),
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
