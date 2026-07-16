import 'package:diapason/components/HomeScreen/home_screen_content.dart';
import 'package:diapason/components/MusicScreen/discover_tab_view.dart';
import 'package:diapason/components/MusicScreen/music_screen_tab_view.dart';
import 'package:diapason/components/MusicScreen/youtube_tab_view.dart';
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
import 'package:diapason/screens/desktop/desktop_nav.dart';
import 'package:diapason/screens/desktop/desktop_search_results.dart';
import 'package:diapason/screens/desktop/desktop_smart_playlists.dart';
import 'package:diapason/screens/genre_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DesktopSearchScope extends InheritedWidget {
  const DesktopSearchScope({super.key, required this.query, required super.child});

  final String query;

  static String of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopSearchScope>()?.query ?? "";

  @override
  bool updateShouldNotify(DesktopSearchScope oldWidget) => query != oldWidget.query;
}

class DesktopContent extends StatelessWidget {
  const DesktopContent({super.key, required this.nav, this.openItem});

  final DesktopNav nav;

  final BaseItemDto? openItem;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: ValueKey((nav, openItem?.id)),
      onGenerateInitialRoutes: (navigator, initialRoute) {
        final routes = <Route<dynamic>>[
          MaterialPageRoute(builder: (_) => _DesktopNavRoot(nav: nav)),
        ];
        if (openItem != null) {
          routes.add(
            MaterialPageRoute(
              settings: RouteSettings(name: AlbumScreen.routeName, arguments: openItem),
              builder: (_) => DesktopAlbumDetail(parent: openItem!),
            ),
          );
        }
        return routes;
      },
      onGenerateRoute: (settings) {
        Widget page;
        switch (settings.name) {
          case AlbumScreen.routeName:
            page = DesktopAlbumDetail(parent: settings.arguments as BaseItemDto);
          case ArtistScreen.routeName:
            page = DesktopArtistDetail(artist: settings.arguments as BaseItemDto);
          case GenreScreen.routeName:
            return MaterialPageRoute(settings: settings, builder: (_) => const GenreScreen());
          default:
            page = _DesktopNavRoot(nav: nav);
        }
        return MaterialPageRoute(settings: settings, builder: (_) => page);
      },
    );
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
      return DesktopSearchResults(query: query);
    }
    switch (widget.nav) {
      case DesktopNav.home:
        return const HomeScreenContent();
      case DesktopNav.discover:
        return const DiscoverTabView();
      case DesktopNav.youtube:
        return const YouTubeTabView();
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
    return Column(
      children: [
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
