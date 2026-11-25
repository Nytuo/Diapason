import 'dart:async';

import 'package:diapason/components/YtDlp/youtube_setup_view.dart';
import 'package:diapason/components/update_dialog.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/screens/album_screen.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/screens/genre_screen.dart';
import 'package:diapason/screens/settings_screen.dart';
import 'package:diapason/screens/analytics_settings_screen.dart';
import 'package:diapason/services/updater_prefs.dart';
import 'package:diapason/screens/desktop/desktop_visualizer_page.dart';
import 'package:diapason/components/visuals/milkdrop_view.dart';
import 'package:diapason/screens/desktop/desktop_command_palette.dart';
import 'package:diapason/services/shortcuts/shortcut_service.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:diapason/screens/desktop/desktop_ambient_background.dart';
import 'package:diapason/screens/desktop/desktop_content.dart';
import 'package:diapason/screens/desktop/desktop_kit.dart';
import 'package:diapason/screens/desktop/desktop_fullscreen_player.dart';
import 'package:diapason/screens/desktop/desktop_header_bar.dart';
import 'package:diapason/screens/desktop/desktop_mini_player.dart';
import 'package:diapason/screens/desktop/desktop_nav.dart';
import 'package:diapason/screens/desktop/desktop_page_frame.dart';
import 'package:diapason/screens/desktop/desktop_player_bar.dart';
import 'package:diapason/screens/desktop/desktop_item_menu.dart';
import 'package:diapason/screens/desktop/desktop_router.dart';
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

class _DesktopShellState extends State<DesktopShell> implements DesktopRouteHost {
  DesktopNav _nav = DesktopNav.home;
  String _searchQuery = "";
  BaseItemDto? _openPlaylist;
  BaseItemDto? _detailItem;
  bool _detailIsArtist = false;
  bool _lyricsOpen = false;
  bool _fullscreen = false;
  bool _visualizerOpen = false;
  DesktopPalette? _palette;
  ThemeData? _themeData;
  bool _miniMode = false;
  Size? _restoreSize;
  final _contentNavigator = DesktopContentNavigatorRef();

  @override
  void initState() {
    super.initState();
    DesktopPointerAnchor.ensureInstalled();
    DesktopRouter.attach(this, visible: _visible);
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
    DesktopRouter.detach(this);
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

  /// The name of the page on screen: the open album, artist, genre or section, else the current tab.
  String _pageTitle(BuildContext context, RouteSettings? top) {
    if (_searchQuery.trim().isNotEmpty) return _nav.label;
    final arguments = top?.arguments;
    switch (top?.name) {
      case AlbumScreen.routeName || ArtistScreen.routeName || GenreScreen.routeName when arguments is BaseItemDto:
        final name = arguments.name;
        if (name != null && name.isNotEmpty) return name;
      case DesktopSectionRoute.routeName when arguments is DesktopSectionRoute:
        return arguments.config.getTitle(AppLocalizations.of(context)!);
      case SettingsScreen.routeName:
        return "Settings";
    }
    return _nav.label;
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

  /// False while another full page (e.g. the iPod shell) covers the shell;
  /// dialogs and menus over it don't count.
  bool _visible() {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route == null) return true;
    if (!route.isActive) return false;
    return route.isCurrent || (route.secondaryAnimation?.value ?? 0) == 0;
  }

  /// Leaves the full-window modes so the content area is on screen.
  Future<bool> _showContent() async {
    if (!_fullscreen && !_visualizerOpen && !_miniMode) return true;
    if (_miniMode) await _exitMiniMode();
    if (_fullscreen) await _toggleFullscreen();
    if (_visualizerOpen && mounted) setState(() => _visualizerOpen = false);
    await WidgetsBinding.instance.endOfFrame;
    return mounted;
  }

  @override
  Future<T?>? pushNamed<T extends Object?>(String routeName, {Object? arguments}) {
    if (!mounted) return null;
    final top = _contentNavigator.topRoute?.settings;
    // Clicking Settings twice shouldn't stack two settings pages.
    if (top != null && top.name == routeName && top.arguments == arguments) return Future<T?>.value();
    return _showContent().then((ok) {
      final navigator = _contentNavigator.current;
      if (!ok || navigator == null) return null;
      return navigator.pushNamed<T>(routeName, arguments: arguments);
    });
  }

  @override
  Future<T?>? pushPage<T extends Object?>(WidgetBuilder builder, {RouteSettings? settings}) {
    if (!mounted) return null;
    return _showContent().then((ok) {
      final navigator = _contentNavigator.current;
      if (!ok || navigator == null) return null;
      return navigator.push<T>(
        MaterialPageRoute<T>(
          settings: settings,
          builder: (context) => DesktopPageFrame(child: builder(context)),
        ),
      );
    });
  }

  @override
  void selectNav(DesktopNav nav) {
    unawaited(_showContent().then((ok) => ok ? _select(nav) : null));
  }

  @override
  void openDetail(BaseItemDto item, {required bool isArtist}) {
    unawaited(_showContent().then((ok) => ok ? _openDetail(item, isArtist: isArtist) : null));
  }

  @override
  void openFullscreenPlayer() {
    if (!_fullscreen) unawaited(_toggleFullscreen());
  }

  @override
  void openLyrics() {
    if (mounted && !_lyricsOpen) setState(() => _lyricsOpen = true);
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
          return Consumer(
            builder: (context, ref, _) {
              final mode = DesktopAmbientMode.fromName(ref.watch(finampSettingsProvider.desktopAmbientMode));
              final palette = DesktopPalette.fromScheme(
                Theme.of(context).colorScheme,
                ambient: mode != DesktopAmbientMode.off,
                reduceEffects: ref.watch(finampSettingsProvider.desktopReduceEffects),
              );
              _palette = palette;
              _themeData = Theme.of(context);
              return DesktopThemeScope(
                palette: palette,
                child: Scaffold(
                  backgroundColor: palette.window,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(child: DesktopAmbientBackground(mode: mode)),
                      _body(palette),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _body(DesktopPalette palette) {
    if (_miniMode) {
      return DesktopMiniPlayer(onExit: _exitMiniMode);
    }
    if (_visualizerOpen) {
      return DesktopVisualizerPage(onClose: () => setState(() => _visualizerOpen = false));
    }
    if (_fullscreen) {
      return DesktopFullscreenPlayer(onExit: _toggleFullscreen);
    }
    const gap = DesktopMetrics.windowGap;
    return Padding(
      padding: const EdgeInsets.all(gap),
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DesktopSidebar(
                  current: _nav,
                  onSelect: _select,
                  onOpenPlaylist: _openPlaylistDetail,
                  openPlaylistId: _openPlaylist?.id,
                  onOpenNowPlaying: _toggleFullscreen,
                ),
                const SizedBox(width: gap),
                Expanded(
                  child: DesktopPanel(
                    child: Column(
                      children: [
                        ValueListenableBuilder<RouteSettings?>(
                          valueListenable: _contentNavigator.topSettings,
                          builder: (context, top, _) => DesktopHeaderBar(
                            title: _pageTitle(context, top),
                            query: _searchQuery,
                            onOpenSearch: _openPalette,
                            onClearSearch: () => setState(() => _searchQuery = ""),
                          ),
                        ),
                        Expanded(
                          child: _contentTheme(
                            palette,
                            DesktopSearchScope(
                              query: parseSearchQuery(_searchQuery).$2,
                              type: parseSearchQuery(_searchQuery).$1,
                              // Switching tab (or opening a detail from outside the navigator) cross-fades
                              // with a small lift; pages pushed inside the navigator use the route transition.
                              child: AnimatedSwitcher(
                                duration: palette.motion(const Duration(milliseconds: 220)),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeIn,
                                transitionBuilder: (child, animation) => FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween<Offset>(
                                      begin: const Offset(0, 0.012),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                                child: DesktopContent(
                                  key: ValueKey((_nav, _openPlaylist?.id, _detailItem?.id, _detailIsArtist)),
                                  nav: _nav,
                                  openItem: _openPlaylist,
                                  detailItem: _detailItem,
                                  detailIsArtist: _detailIsArtist,
                                  navigatorRef: _contentNavigator,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_lyricsOpen) ...[
                  const SizedBox(width: gap),
                  DesktopPanel(
                    chrome: true,
                    width: DesktopMetrics.lyricsWidth,
                    child: Column(
                      children: [
                        _lyricsHeader(palette),
                        const Expanded(child: LyricsView()),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: gap),
          DesktopPlayerBar(
            lyricsOpen: _lyricsOpen,
            onToggleLyrics: () => setState(() => _lyricsOpen = !_lyricsOpen),
            onMiniPlayer: _enterMiniMode,
            onFullscreen: _toggleFullscreen,
            onOpenVisualizer: MilkdropShader.platformSupported ? () => setState(() => _visualizerOpen = true) : null,
            onOpenLibraryItem: _openDetail,
          ),
        ],
      ),
    );
  }

  /// Pages inside the content panel draw on its fill: transparent scaffolds,
  /// and a fade-through between pages so two translucent pages never overlap.
  Widget _contentTheme(DesktopPalette palette, Widget child) {
    // The album theme from PlayerScreenTheme, which sits below this State's context.
    final theme = _themeData ?? Theme.of(context);
    final fade = DesktopFadeThroughPageTransitionsBuilder(reduceEffects: palette.reduceEffects);
    return Theme(
      data: palette
          .pageTheme(theme)
          .copyWith(
            pageTransitionsTheme: PageTransitionsTheme(
              builders: {for (final platform in TargetPlatform.values) platform: fade},
            ),
          ),
      child: child,
    );
  }

  Widget _lyricsHeader(DesktopPalette palette) {
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: 18, right: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.borderSubtle)),
      ),
      child: Row(
        children: [
          Text("Lyrics", style: palette.title.copyWith(fontSize: 15)),
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
