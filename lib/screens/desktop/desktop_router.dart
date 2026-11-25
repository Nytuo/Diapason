import 'dart:async';
import 'dart:math';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/desktop/desktop_nav.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:flutter/material.dart';

/// What the desktop shell offers to [DesktopRouter] while it is on screen.
abstract interface class DesktopRouteHost {
  /// Pushes a named route into the shell's content area. Returns null when
  /// the route can't be shown there (the caller then falls back to the root
  /// navigator).
  Future<T?>? pushNamed<T extends Object?>(String routeName, {Object? arguments});

  /// Pushes a page into the shell's content area, wrapped in the desktop page frame.
  Future<T?>? pushPage<T extends Object?>(WidgetBuilder builder, {RouteSettings? settings});

  /// Switches the sidebar tab.
  void selectNav(DesktopNav nav);

  /// Opens an already-resolved album or artist as a detail page.
  void openDetail(BaseItemDto item, {required bool isArtist});

  void openFullscreenPlayer();

  void openLyrics();
}

/// Routes navigation into the desktop shell while it is on screen, so screens
/// that would otherwise push a full-screen mobile route open inside the shell's
/// content area instead. Without a shell (mobile, TV, watch, tests) every call
/// behaves exactly like the plain [Navigator] call it replaces.
class DesktopRouter {
  DesktopRouter._();

  static DesktopRouteHost? _host;
  static bool Function()? _hostVisible;

  /// Registers the shell; [visible] says whether no other full page covers it.
  static void attach(DesktopRouteHost host, {bool Function()? visible}) {
    _host = host;
    _hostVisible = visible;
  }

  static void detach(DesktopRouteHost host) {
    if (identical(_host, host)) {
      _host = null;
      _hostVisible = null;
    }
  }

  /// The shell, when it is mounted and not covered by another page.
  static DesktopRouteHost? get host {
    final host = _host;
    if (host == null) return null;
    if (!(_hostVisible?.call() ?? true)) return null;
    return host;
  }

  /// Whether navigation is currently redirected into the desktop shell.
  static bool get isActive => host != null;

  /// Whether [context] is inside the desktop shell (its content area, sidebar or player bar).
  static bool isInShell(BuildContext context) => context.getInheritedWidgetOfExactType<DesktopThemeScope>() != null;

  /// Routes that always belong to the root navigator: they replace the whole
  /// app (login, splash, other shells) rather than show inside the desktop one.
  static const rootOnlyRoutes = <String>{
    "/",
    "login/splash",
    "/login",
    "/desktop",
    "/ipod",
    "/tv/profiles",
    "/tv/profiles/edit",
    "/watch",
  };

  /// Routes the shell shows with its own chrome instead of a page.
  static const _musicRoute = MusicScreen.routeName;
  static const _smartPlaylistsRoute = "/smart-playlists";
  static const _radioRoute = "/radio";
  static const _playerRoute = "/nowplaying";
  static const _lyricsRoute = "/lyrics";

  /// Drop-in replacement for `Navigator.of(context).pushNamed(...)`.
  static Future<T?> pushNamed<T extends Object?>(BuildContext context, String routeName, {Object? arguments}) {
    final redirected = _redirectNamed<T>(routeName, arguments);
    if (redirected != null) return redirected;
    return Navigator.of(context).pushNamed<T>(routeName, arguments: arguments);
  }

  /// Like [pushNamed], for callers that already hold a [NavigatorState].
  static Future<T?> pushNamedOn<T extends Object?>(NavigatorState navigator, String routeName, {Object? arguments}) {
    final redirected = _redirectNamed<T>(routeName, arguments);
    if (redirected != null) return redirected;
    return navigator.pushNamed<T>(routeName, arguments: arguments);
  }

  /// Drop-in replacement for `Navigator.of(context).push(MaterialPageRoute(builder: builder))`.
  static Future<T?> pushPage<T extends Object?>(
    BuildContext context,
    WidgetBuilder builder, {
    RouteSettings? settings,
    bool fullscreenDialog = false,
  }) {
    final redirected = host?.pushPage<T>(builder, settings: settings);
    if (redirected != null) return redirected;
    return Navigator.of(
      context,
    ).push<T>(MaterialPageRoute<T>(builder: builder, settings: settings, fullscreenDialog: fullscreenDialog));
  }

  /// Like [pushPage], for callers that already hold a [NavigatorState].
  static Future<T?> pushPageOn<T extends Object?>(NavigatorState navigator, WidgetBuilder builder) {
    final redirected = host?.pushPage<T>(builder);
    if (redirected != null) return redirected;
    return navigator.push<T>(MaterialPageRoute<T>(builder: builder));
  }

  static Future<T?>? _redirectNamed<T extends Object?>(String routeName, Object? arguments) {
    final host = DesktopRouter.host;
    if (host == null || rootOnlyRoutes.contains(routeName)) return null;
    switch (routeName) {
      case _musicRoute:
        final type = arguments is ContentType ? arguments : null;
        host.selectNav(DesktopNav.values.firstWhere((n) => n.contentType == type, orElse: () => DesktopNav.home));
        return Future<T?>.value();
      case _smartPlaylistsRoute:
        host.selectNav(DesktopNav.smart);
        return Future<T?>.value();
      case _radioRoute:
        host.selectNav(DesktopNav.radio);
        return Future<T?>.value();
      case _playerRoute:
        host.openFullscreenPlayer();
        return Future<T?>.value();
      case _lyricsRoute:
        host.openLyrics();
        return Future<T?>.value();
    }
    return host.pushNamed<T>(routeName, arguments: arguments);
  }
}

/// Opens a home-screen section / "show all" list: a desktop page inside the
/// shell, the mobile [MusicScreen] elsewhere.
Future<void> openSectionScreen(
  BuildContext context,
  HomeScreenSectionConfiguration config, {
  bool Function(ItemFilter)? allowFilters,
}) {
  final host = DesktopRouter.host;
  final redirected = host?.pushNamed<void>(
    DesktopSectionRoute.routeName,
    arguments: DesktopSectionRoute(config, allowFilters: allowFilters),
  );
  if (redirected != null) return redirected;
  return Navigator.of(context).push(
    MaterialPageRoute<MusicScreen>(
      builder: (context) => MusicScreen(singleTabConfig: config, allowFilters: allowFilters),
    ),
  );
}

/// Arguments of the desktop-only section page route.
class DesktopSectionRoute {
  const DesktopSectionRoute(this.config, {this.allowFilters});

  static const routeName = "/desktop/section";

  final HomeScreenSectionConfiguration config;
  final bool Function(ItemFilter)? allowFilters;
}

/// `showModalBottomSheet` on mobile; a centred dialog while the desktop shell is
/// on screen, where a sheet sliding up from the bottom of the window (or of the
/// content pane) looks out of place.
Future<T?> showAdaptiveModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool showDragHandle = false,
  bool useSafeArea = false,
  BoxConstraints? constraints,
  RouteSettings? routeSettings,
}) {
  if (DesktopRouter.isActive) {
    return showDialog<T>(
      context: context,
      useRootNavigator: true,
      routeSettings: routeSettings,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        return Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: min(constraints?.maxWidth ?? 560, 640), maxHeight: size.height * 0.8),
            child: Padding(padding: const EdgeInsets.only(top: 8), child: builder(context)),
          ),
        );
      },
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    constraints: constraints,
    routeSettings: routeSettings,
  );
}
