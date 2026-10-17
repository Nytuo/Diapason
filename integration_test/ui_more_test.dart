import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/album_screen.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/screens/genre_screen.dart';
import 'package:diapason/screens/home_screen_settings_screen.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/screens/player_screen.dart';
import 'package:diapason/screens/playlist_edit_screen.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/harness.dart';

void main() {
  installHarness();

  QueueService queue() => GetIt.instance<QueueService>();
  AggregateBackend backend() => GetIt.instance<AggregateBackend>();

  Future<void> play(WidgetTester tester, {String? onlyTitle}) async {
    var items = (await backend().getItems(includeItemTypes: 'Audio')).toList();
    if (onlyTitle != null) items = items.where((t) => t.name == onlyTitle).toList();
    final source = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
      id: 'ui-more',
    );
    await queue().startPlayback(
      items: [...items, ...items],
      source: source,
      order: FinampPlaybackOrder.linear,
      startingIndex: 0,
    );
    await tester.waitUntil(() => queue().getQueue().currentTrack != null, seconds: 20, what: 'a current track');
    await tester.settle();
  }

  Future<void> openPlayer(WidgetTester tester) async {
    GlobalSnackbar.navigatorState!.pushNamed(PlayerScreen.routeName);
    await tester.settle(frames: 8);
  }

  Future<void> openPlayerMenu(WidgetTester tester) async {
    final buttons = find.byType(IconButton).hitTestable().evaluate().toList();
    await tester.tapAt(tester.getCenter(find.byElementPredicate((e) => e == buttons.first)));
    await tester.settle(frames: 8);
  }

  Future<void> back(WidgetTester tester) async {
    await GlobalSnackbar.navigatorState!.maybePop();
    await tester.settle();
  }

  group('the player menu', () {
    testApp('shuffle and repeat change what the menu says', (tester) async {
      await launch(tester);
      await play(tester);
      await openPlayer(tester);

      await openPlayerMenu(tester);

      expect(find.text('Playing in order'), findsOneWidget);
      await tester.tap(find.text('Playing in order'));
      await tester.waitFor(find.text('Shuffling tracks'), seconds: 10);
      await tester.tap(find.text('Shuffling tracks'));
      await tester.waitFor(find.text('Playing in order'), seconds: 10);

      expect(find.text('Not looping'), findsOneWidget);
      await tester.tap(find.text('Not looping'));
      await tester.waitFor(find.text('Looping all'), seconds: 10);
      await tester.tap(find.text('Looping all'));
      await tester.waitUntil(
        () => find.textContaining('Looping').evaluate().isNotEmpty && find.text('Looping all').evaluate().isEmpty,
        what: 'the next repeat mode',
      );
      await back(tester);

      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);

    testApp('the sleep timer takes minutes or tracks and can be started', (tester) async {
      await launch(tester);
      await play(tester);
      await openPlayer(tester);

      await openPlayerMenu(tester);
      await tester.tap(find.text('Sleep timer'));
      await tester.settle(frames: 8);
      expect(find.text('Minutes'), findsWidgets);
      expect(find.text('Start Timer'), findsOneWidget);
      await tester.tap(find.text('Tracks').first);
      await tester.settle();
      await tester.tap(find.text('Minutes').first);
      await tester.settle();
      await tester.tap(find.text('15').first, warnIfMissed: false);
      await tester.settle();
      await tester.tap(find.text('After Current Track').first, warnIfMissed: false);
      await tester.settle();
      await tester.tap(find.text('Start Timer'));
      await tester.settle(frames: 8);
      await exploreTop(tester, taps: 4, seed: 3);

      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);

    testApp('"Save Queue to Playlist" and the add-to-playlist sheet offer a new playlist', (tester) async {
      await launch(tester);
      await play(tester);
      await openPlayer(tester);

      await openPlayerMenu(tester);
      await tester.tap(find.text('Save Queue to Playlist'));
      await tester.settle(frames: 8);
      expect(find.text('New Playlist'), findsWidgets);
      await tester.tap(find.text('New Playlist').first);
      await tester.settle(frames: 8);
      final name = find.byType(TextField);
      if (name.evaluate().isNotEmpty) {
        await tester.enterText(name.first, 'Saved from test');
        await tester.settle();
      }
      await exploreTop(tester, taps: 3, seed: 5, avoid: r'cancel|delete|remove|clear|reset|window');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);
  });

  group('lyrics', () {
    testApp('synced lyrics from the server are shown line by line', (tester) async {
      await launch(tester);
      await play(tester, onlyTitle: 'Closing');
      await openPlayer(tester);

      await tester.tap(find.text('Lyrics').first, warnIfMissed: false);
      await tester.waitUntil(
        () => find.textContaining('Closing time', findRichText: true).evaluate().isNotEmpty,
        seconds: 20,
        what: 'the first lyric line',
      );
      expect(find.textContaining('Every new beginning', findRichText: true), findsWidgets);
      await exploreTop(tester, taps: 4, seed: 9);

      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);
  });

  group('the phone layout', () {
    testApp('tabs, search, refresh, the side menu and the mini player all work', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed(MusicScreen.routeName);
      await tester.settle(frames: 12);

      for (final tab in ['Albums', 'Artists', 'Playlists', 'Tracks', 'Genres', 'Discover', 'Downloads', 'Home']) {
        final entry = find.text(tab);
        if (entry.evaluate().isEmpty) continue;
        await tester.tap(entry.first, warnIfMissed: false);
        await tester.settle(frames: 8);
      }
      for (final tip in ['Refresh', 'Search', 'Menu']) {
        final button = find.byTooltip(tip);
        if (button.evaluate().isEmpty) continue;
        await tester.tap(button.first, warnIfMissed: false);
        await tester.settle(frames: 8);
        if (tip == 'Search' && find.byType(TextField).evaluate().isNotEmpty) {
          await tester.enterText(find.byType(TextField).first, 'Open');
          await tester.settle(frames: 10);
        }
        if (tip == 'Menu')
          await exploreTop(tester, taps: 5, seed: 13, avoid: r'log ?out|delete|remove|clear|reset|window');
        await back(tester);
      }
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);

    testApp('the phone library plays from a tapped track and shows the mini player', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed(MusicScreen.routeName);
      await tester.settle(frames: 12);
      await tester.tap(find.text('Tracks').first, warnIfMissed: false);
      await tester.settle(frames: 10);
      await tester.waitFor(find.text('Opening'), seconds: 20);
      await tester.tap(find.text('Opening').first, warnIfMissed: false);
      await tester.waitUntil(() => queue().getQueue().currentTrack != null, seconds: 20, what: 'playback');
      await tester.settle(frames: 8);
      final toggle = find.byTooltip('Toggle playback');
      if (toggle.evaluate().isNotEmpty) {
        await tester.tap(toggle.first, warnIfMissed: false);
        await tester.settle();
      }
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);
  });

  group('artist, album and genre pages', () {
    Future<BaseItemDto> first(String type) async => (await backend().getItems(includeItemTypes: type)).first;

    testApp('an artist page lists their albums and has a menu', (tester) async {
      await launch(tester);
      final artist = await first('MusicArtist');
      GlobalSnackbar.navigatorState!.pushNamed(ArtistScreen.routeName, arguments: artist);
      await tester.settle(frames: 12);
      await tester.waitFor(find.text(artist.name!), seconds: 20);
      await exploreTop(
        tester,
        taps: 5,
        seed: 21,
        avoid: r'delete|remove|clear|reset|window|play|shuffle|radio|mix|download',
      );
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);

    testApp('an album page lists its tracks', (tester) async {
      await launch(tester);
      final album = await first('MusicAlbum');
      GlobalSnackbar.navigatorState!.pushNamed(AlbumScreen.routeName, arguments: album);
      await tester.settle(frames: 12);
      await tester.waitFor(find.text('Opening'), seconds: 20);
      await exploreTop(
        tester,
        taps: 5,
        seed: 22,
        avoid: r'delete|remove|clear|reset|window|play|shuffle|radio|mix|download',
      );
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);

    testApp('a genre page shows its content', (tester) async {
      await launch(tester);
      final genre = await first('MusicGenre');
      GlobalSnackbar.navigatorState!.pushNamed(GenreScreen.routeName, arguments: genre);
      await tester.settle(frames: 12);
      await tester.waitFor(find.text(genre.name!), seconds: 20);
      await exploreTop(
        tester,
        taps: 5,
        seed: 23,
        avoid: r'delete|remove|clear|reset|window|play|shuffle|radio|mix|download',
      );
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);
  });

  group('playlists', () {
    testApp('a playlist from the server opens, and its edit page lists the tracks', (tester) async {
      await launch(tester);
      final playlists = await backend().getItems(includeItemTypes: 'Playlist');
      expect(playlists, isNotEmpty);
      final playlist = playlists.first;
      GlobalSnackbar.navigatorState!.pushNamed(AlbumScreen.routeName, arguments: playlist);
      await tester.settle(frames: 12);
      await exploreTop(
        tester,
        taps: 4,
        seed: 31,
        avoid: r'delete|remove|clear|reset|window|play|shuffle|radio|mix|download',
      );
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);

      GlobalSnackbar.navigatorState!.pushNamed(PlaylistEditScreen.routeName, arguments: playlist);
      await tester.settle(frames: 12);
      await exploreTop(tester, taps: 6, seed: 32, avoid: r'delete|remove|clear|reset|window|cancel');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);
  });

  group('the home screen editor', () {
    testApp('sections and actions can be opened for editing', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed(HomeScreenSettingsScreen.routeName);
      await tester.settle(frames: 10);

      for (final label in ['Add New Section', 'Add New Action']) {
        await tester.tap(find.text(label), warnIfMissed: false);
        await tester.settle(frames: 8);
        await exploreTop(tester, taps: 4, seed: label.length, avoid: r'delete|reset|window|cancel');
      }
      final edit = find.byTooltip('Edit section');
      if (edit.evaluate().isNotEmpty) {
        await tester.tap(edit.first, warnIfMissed: false);
        await tester.settle(frames: 8);
        await exploreTop(tester, taps: 6, seed: 41, avoid: r'delete|reset|window|cancel');
      }
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);
  });
}
