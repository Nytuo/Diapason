import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/radio_screen.dart';
import 'package:diapason/components/HomeScreen/home_screen_content.dart';
import 'package:diapason/components/MusicScreen/discover_tab_view.dart';
import 'package:diapason/components/MusicScreen/music_screen_tab_view.dart';
import 'package:diapason/components/MusicScreen/youtube_tab_view.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/components/MusicScreen/sort_and_filter_row.dart';
import 'package:diapason/components/PlayerScreen/queue_list.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_models.dart';
import 'package:diapason/screens/album_screen.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/screens/desktop/desktop_album_detail.dart';
import 'package:diapason/screens/desktop/desktop_artist_detail.dart';
import 'package:diapason/screens/desktop/desktop_folders.dart';
import 'package:diapason/screens/desktop/desktop_genre_detail.dart';
import 'package:diapason/screens/desktop/desktop_page_frame.dart';
import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/screens/desktop/desktop_section_page.dart';
import 'package:diapason/screens/desktop/desktop_home.dart';
import 'package:diapason/screens/desktop/desktop_nav.dart';
import 'package:diapason/screens/desktop/desktop_search_results.dart';
import 'package:diapason/screens/desktop/desktop_smart_playlists.dart';
import 'package:diapason/screens/genre_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DesktopSearchScope extends InheritedWidget {
  const DesktopSearchScope({super.key, required this.query, this.type, required super.child});

  final String query;

  /// Content type picked with a `song:`-style prefix, if any.
  final ContentType? type;

  static ContentType? typeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopSearchScope>()?.type;

  static String of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopSearchScope>()?.query ?? "";

  @override
  bool updateShouldNotify(DesktopSearchScope oldWidget) => query != oldWidget.query || type != oldWidget.type;
}

/// Lets the shell reach the content area's navigator, which is rebuilt every
/// time the sidebar tab or the opened item changes.
class DesktopContentNavigatorRef {
  GlobalKey<NavigatorState>? _key;
  final _top = <Route<dynamic>>[];

  NavigatorState? get current => _key?.currentState;

  /// The route on top of the content area, if any.
  Route<dynamic>? get topRoute => _top.isEmpty ? null : _top.last;

  /// The settings of the route on top, for whoever shows the current page's name (the header bar).
  final topSettings = ValueNotifier<RouteSettings?>(null);

  void _publishTop() {
    final settings = topRoute?.settings;
    // After the frame: this runs from navigator callbacks, which can happen while building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (topSettings.value != settings) topSettings.value = settings;
    });
  }
}

class DesktopContent extends StatelessWidget {
  const DesktopContent({
    super.key,
    required this.nav,
    this.openItem,
    this.detailItem,
    this.detailIsArtist = false,
    this.navigatorRef,
    @visibleForTesting this.rootBuilder,
  });

  final DesktopNav nav;

  final BaseItemDto? openItem;

  /// An album or artist opened as a detail page over the current tab, e.g. from
  /// the player bar's "go to album/artist" actions.
  final BaseItemDto? detailItem;
  final bool detailIsArtist;

  /// Filled with the content navigator so the shell can push pages into it.
  final DesktopContentNavigatorRef? navigatorRef;

  /// Replaces the tab's root page (tests only).
  final WidgetBuilder? rootBuilder;

  @override
  Widget build(BuildContext context) {
    // While searching, drop any album/artist/playlist detail pages so the
    // search results (which live on the root route) are what's on screen.
    final searching = DesktopSearchScope.of(context).trim().isNotEmpty;
    final openItem = searching ? null : this.openItem;
    final detailItem = searching ? null : this.detailItem;
    // Every named route of the app can open in the content area; screens
    // without a desktop page are shown in the desktop page frame.
    final appRoutes = context.findAncestorWidgetOfExactType<MaterialApp>()?.routes ?? const {};
    return _ContentNavigator(
      key: ValueKey((nav, openItem?.id, detailItem?.id, detailIsArtist, searching)),
      navigatorRef: navigatorRef,
      onGenerateInitialRoutes: (navigator, initialRoute) {
        final routes = <Route<dynamic>>[MaterialPageRoute(builder: rootBuilder ?? (_) => _DesktopNavRoot(nav: nav))];
        if (openItem != null) {
          routes.add(
            MaterialPageRoute(
              settings: RouteSettings(name: AlbumScreen.routeName, arguments: openItem),
              builder: (_) => DesktopAlbumDetail(parent: openItem),
            ),
          );
        }
        if (detailItem != null) {
          routes.add(
            MaterialPageRoute(
              settings: RouteSettings(
                name: detailIsArtist ? ArtistScreen.routeName : AlbumScreen.routeName,
                arguments: detailItem,
              ),
              builder: (_) =>
                  detailIsArtist ? DesktopArtistDetail(artist: detailItem) : DesktopAlbumDetail(parent: detailItem),
            ),
          );
        }
        return routes;
      },
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: desktopPageBuilder(settings, appRoutes, nav: nav),
      ),
    );
  }
}

/// The desktop page for a named route pushed into the content area.
@visibleForTesting
WidgetBuilder desktopPageBuilder(
  RouteSettings settings,
  Map<String, WidgetBuilder> appRoutes, {
  DesktopNav nav = DesktopNav.home,
}) {
  final arguments = settings.arguments;
  switch (settings.name) {
    case AlbumScreen.routeName when arguments is BaseItemDto:
      return (_) => DesktopAlbumDetail(parent: arguments);
    case ArtistScreen.routeName when arguments is BaseItemDto:
      return (_) => DesktopArtistDetail(artist: arguments);
    case GenreScreen.routeName when arguments is BaseItemDto:
      return (_) => DesktopGenreDetail(genre: arguments);
    case DesktopSectionRoute.routeName when arguments is DesktopSectionRoute:
      return (_) => DesktopSectionPage(route: arguments);
  }
  final builder = appRoutes[settings.name];
  if (builder != null) return (context) => DesktopPageFrame(child: builder(context));
  return (_) => _DesktopNavRoot(nav: nav);
}

/// The content area's navigator; registers itself with [navigatorRef] for as
/// long as it is the one on screen.
class _ContentNavigator extends StatefulWidget {
  const _ContentNavigator({
    super.key,
    required this.navigatorRef,
    required this.onGenerateInitialRoutes,
    required this.onGenerateRoute,
  });

  final DesktopContentNavigatorRef? navigatorRef;
  final RouteListFactory onGenerateInitialRoutes;
  final RouteFactory onGenerateRoute;

  @override
  State<_ContentNavigator> createState() => _ContentNavigatorState();
}

class _ContentNavigatorState extends State<_ContentNavigator> {
  final _key = GlobalKey<NavigatorState>();
  late final _observer = _TopRouteObserver(this);
  final _routes = <Route<dynamic>>[];

  void _register() {
    final ref = widget.navigatorRef;
    if (ref == null) return;
    ref._key = _key;
    ref._top
      ..clear()
      ..addAll(_routes);
    ref._publishTop();
  }

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void didUpdateWidget(_ContentNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigatorRef != widget.navigatorRef) _register();
  }

  @override
  void dispose() {
    final ref = widget.navigatorRef;
    if (ref != null && ref._key == _key) {
      ref._key = null;
      ref._top.clear();
    }
    super.dispose();
  }

  void _changed() {
    final ref = widget.navigatorRef;
    if (ref != null && ref._key == _key) _register();
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: _key,
      observers: [_observer],
      onGenerateInitialRoutes: widget.onGenerateInitialRoutes,
      onGenerateRoute: widget.onGenerateRoute,
    );
  }
}

class _TopRouteObserver extends NavigatorObserver {
  _TopRouteObserver(this._state);

  final _ContentNavigatorState _state;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _state._routes.add(route);
    _state._changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _state._routes.remove(route);
    _state._changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _state._routes.remove(route);
    _state._changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _state._routes.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) {
      _state._routes[i] = newRoute;
    } else if (newRoute != null) {
      _state._routes.add(newRoute);
    }
    _state._changed();
  }
}

class _DesktopNavRoot extends ConsumerStatefulWidget {
  const _DesktopNavRoot({required this.nav});

  final DesktopNav nav;

  @override
  ConsumerState<_DesktopNavRoot> createState() => _DesktopNavRootState();
}

class _DesktopNavRootState extends ConsumerState<_DesktopNavRoot> {
  final Map<ContentType, SortAndFilterController> _controllers = {};
  final _queueScrollController = ScrollController();
  final _previousTracksHeaderKey = GlobalKey();
  final _jumpToCurrentKey = GlobalKey<JumpToCurrentButtonState>();

  QueueItemSource get _source => QueueItemSource.rawId(
    type: QueueItemSourceType.allTracks,
    name: const QueueItemSourceName(type: QueueItemSourceNameType.shuffleAll),
    id: "shuffleAll",
  );

  @override
  void dispose() {
    _queueScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = DesktopSearchScope.of(context).trim();
    if (query.isNotEmpty) {
      return DesktopSearchResults(query: query, initialType: DesktopSearchScope.typeOf(context));
    }
    switch (widget.nav) {
      case DesktopNav.home:
        return const DesktopHome();
      case DesktopNav.discover:
        return const DiscoverTabView();
      case DesktopNav.youtube:
        return ref.watch(youTubeAvailableProvider) ? const YouTubeTabView() : const HomeScreenContent();
      case DesktopNav.radio:
        return const RadioStationsView(showAddButton: true);
      case DesktopNav.folders:
        return const DesktopFolders();
      case DesktopNav.smart:
        return const DesktopSmartPlaylists();
      case DesktopNav.queue:
        return QueueList(
          scrollController: _queueScrollController,
          previousTracksHeaderKey: _previousTracksHeaderKey,
          jumpToCurrentKey: _jumpToCurrentKey,
        );
      default:
        return _libraryTab(widget.nav.contentType!);
    }
  }

  Widget _libraryTab(ContentType tab) {
    final searchQuery = DesktopSearchScope.of(context);
    final controller = _controllers[tab] ??= SortAndFilterController.trackSettings(tab);
    final sortConfig = ref.watch(resolveSortProvider(controller)).copyWithSearch(searchQuery);
    final displayable = MusicScreenPlayable(
      tab: tab,
      library: currentLibraryPlaceholder,
      source: _source,
      sortConfig: sortConfig,
    );
    final p = DesktopThemeScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Chilpa-style page title above the sort and filter controls.
        Padding(
          padding: const EdgeInsets.fromLTRB(DesktopMetrics.pagePadding, 14, DesktopMetrics.pagePadding, 2),
          child: Text(
            widget.nav.label,
            style: TextStyle(color: p.textPrimary, fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: -0.5),
          ),
        ),
        SortAndFilterRow(tabType: tab, controller: controller),
        Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: MusicScreenTabView(displayable: displayable),
          ),
        ),
      ],
    );
  }
}
