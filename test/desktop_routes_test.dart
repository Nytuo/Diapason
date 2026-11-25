import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/desktop/desktop_content.dart';
import 'package:diapason/screens/desktop/desktop_genre_detail.dart';
import 'package:diapason/screens/desktop/desktop_nav.dart';
import 'package:diapason/screens/desktop/desktop_page_frame.dart';
import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/genre_screen.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/screens/playlist_edit_screen.dart';
import 'package:diapason/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _layoutRoute = '/settings/layout';

/// Mirrors what DesktopShell does as a route host, around a real DesktopContent.
class _TestHost implements DesktopRouteHost {
  final ref = DesktopContentNavigatorRef();
  final selected = <DesktopNav>[];

  @override
  Future<T?>? pushNamed<T extends Object?>(String routeName, {Object? arguments}) =>
      ref.current?.pushNamed<T>(routeName, arguments: arguments);

  @override
  Future<T?>? pushPage<T extends Object?>(WidgetBuilder builder, {RouteSettings? settings}) => ref.current?.push<T>(
    MaterialPageRoute<T>(
      settings: settings,
      builder: (context) => DesktopPageFrame(child: builder(context)),
    ),
  );

  @override
  void selectNav(DesktopNav nav) => selected.add(nav);

  @override
  void openDetail(BaseItemDto item, {required bool isArtist}) {}

  @override
  void openFullscreenPlayer() {}

  @override
  void openLyrics() {}
}

final _contentKey = GlobalKey();
final _rootNavigatorKey = GlobalKey<NavigatorState>();

Widget _page(String label) => Builder(
  builder: (context) => Scaffold(
    appBar: AppBar(title: Text(label)),
    body: TextButton(
      // A settings list pushing its subpage the plain way.
      onPressed: () => Navigator.of(context).pushNamed(_layoutRoute),
      child: Text('open from $label'),
    ),
  ),
);

/// The shell's layout reduced to what routing needs: chrome outside the
/// content navigator (header, menus) and the content area itself.
Future<void> _pumpShell(WidgetTester tester, _TestHost? host) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: _rootNavigatorKey,
      routes: {
        SettingsScreen.routeName: (_) => _page('settings page'),
        _layoutRoute: (_) => _page('layout page'),
        PlaylistEditScreen.routeName: (context) =>
            _page('edit ${(ModalRoute.settingsOf(context)!.arguments as BaseItemDto).name}'),
      },
      home: DesktopThemeScope(
        palette: DesktopPalette.fromScheme(const ColorScheme.dark()),
        child: Scaffold(
          body: Column(
            children: [
              Builder(
                builder: (context) => Row(
                  children: [
                    TextButton(
                      onPressed: () => DesktopRouter.pushNamed(context, SettingsScreen.routeName),
                      child: const Text('header settings'),
                    ),
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        useRootNavigator: true,
                        builder: (context) => Dialog(
                          child: TextButton(
                            // Same steps as EditItemMenuEntry.
                            onPressed: () {
                              Navigator.pop(context);
                              DesktopRouter.pushNamed(
                                context,
                                PlaylistEditScreen.routeName,
                                arguments: BaseItemDto(id: BaseItemId('p1'), name: 'Mix', type: 'Playlist'),
                              );
                            },
                            child: const Text('menu edit'),
                          ),
                        ),
                      ),
                      child: const Text('open menu'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: KeyedSubtree(
                  key: _contentKey,
                  child: DesktopContent(
                    nav: DesktopNav.home,
                    navigatorRef: host?.ref,
                    rootBuilder: (_) => const Center(child: Text('tab root')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _inContent(String text) => find.descendant(of: find.byKey(_contentKey), matching: find.text(text));

void main() {
  late _TestHost host;

  setUp(() {
    host = _TestHost();
    DesktopRouter.attach(host);
  });

  tearDown(() => DesktopRouter.detach(host));

  testWidgets('header settings opens inside the content area, not as a full-screen route', (tester) async {
    await _pumpShell(tester, host);

    await tester.tap(find.text('header settings'));
    await tester.pumpAndSettle();

    expect(_inContent('settings page'), findsOneWidget);
    expect(find.byType(DesktopPageFrame), findsOneWidget);
    // The shell's own chrome is still on screen: nothing was pushed on the root navigator.
    expect(find.text('header settings'), findsOneWidget);
    expect(_rootNavigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('a settings subpage pushed the plain way stays in the content area', (tester) async {
    await _pumpShell(tester, host);
    await tester.tap(find.text('header settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open from settings page'));
    await tester.pumpAndSettle();

    expect(_inContent('layout page'), findsOneWidget);
    expect(_rootNavigatorKey.currentState!.canPop(), isFalse);

    // Back returns to settings, still in the shell.
    host.ref.current!.pop();
    await tester.pumpAndSettle();
    expect(_inContent('settings page'), findsOneWidget);
  });

  testWidgets('a context-menu action (edit playlist) closes the menu and opens in the content area', (tester) async {
    await _pumpShell(tester, host);

    await tester.tap(find.text('open menu'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    await tester.tap(find.text('menu edit'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(_inContent('edit Mix'), findsOneWidget);
    expect(_rootNavigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('the content navigator reports its top route to the shell', (tester) async {
    await _pumpShell(tester, host);
    expect(host.ref.topRoute, isNotNull);

    await tester.tap(find.text('header settings'));
    await tester.pumpAndSettle();
    expect(host.ref.topRoute!.settings.name, SettingsScreen.routeName);
  });

  testWidgets('the library route switches the sidebar tab instead of opening a page', (tester) async {
    await _pumpShell(tester, host);
    final context = tester.element(find.text('tab root'));

    await DesktopRouter.pushNamed<void>(context, MusicScreen.routeName, arguments: ContentType.tracks);

    expect(host.selected, [DesktopNav.songs]);
  });

  testWidgets('genre, album and section routes get desktop pages', (tester) async {
    await _pumpShell(tester, host);
    final context = tester.element(find.text('tab root'));
    final genre = BaseItemDto(id: BaseItemId('g1'), name: 'Jazz', type: 'MusicGenre');

    final page = desktopPageBuilder(RouteSettings(name: GenreScreen.routeName, arguments: genre), const {})(context);

    expect(page, isA<DesktopGenreDetail>());
    expect((page as DesktopGenreDetail).genre, genre);
  });

  testWidgets('without the desktop shell, routes are pushed exactly as before', (tester) async {
    DesktopRouter.detach(host);
    await _pumpShell(tester, null);

    await tester.tap(find.text('header settings'));
    await tester.pumpAndSettle();

    expect(_inContent('settings page'), findsNothing);
    expect(find.text('settings page'), findsOneWidget);
    expect(_rootNavigatorKey.currentState!.canPop(), isTrue);
  });

  testWidgets('sheets become dialogs only while the desktop shell is active', (tester) async {
    await _pumpShell(tester, host);
    final context = tester.element(find.text('tab root'));

    showAdaptiveModalSheet<void>(context: context, builder: (_) => const Text('sheet body'));
    await tester.pumpAndSettle();
    expect(find.ancestor(of: find.text('sheet body'), matching: find.byType(Dialog)), findsOneWidget);
    Navigator.of(tester.element(find.text('sheet body'))).pop();
    await tester.pumpAndSettle();

    DesktopRouter.detach(host);
    showAdaptiveModalSheet<void>(context: context, builder: (_) => const Text('sheet body'));
    await tester.pumpAndSettle();
    expect(find.ancestor(of: find.text('sheet body'), matching: find.byType(BottomSheet)), findsOneWidget);
  });
}
