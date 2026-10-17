import 'dart:async';

import 'package:diapason/components/MusicScreen/youtube_results.dart';
import 'package:diapason/components/YtDlp/youtube_setup_view.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/stub_youtube.dart';
import 'support/test_env.dart';

BaseItemDto _track(String id, String title, String artist) => ytTrack(id, title, artist);

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  late TestEnv env;
  late StubYouTube youtube;
  late YouTubeAvailability availability;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    youtube = StubYouTube();
    availability = YouTubeAvailability();
    GetIt.instance
      ..registerSingleton<YouTubeService>(youtube)
      ..registerSingleton<YouTubeAvailability>(availability)
      ..registerSingleton<UploaderClient>(UploaderClient());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await env.dispose();
  });

  group('Library | YouTube switch', () {
    testWidgets('shows both choices and reports the pick', (tester) async {
      bool? picked;
      await tester.pumpWidget(_app(SearchSourceSwitcher(youtube: false, onChanged: (v) => picked = v)));

      expect(find.text('Library'), findsOneWidget);
      expect(find.text('YouTube'), findsOneWidget);

      await tester.tap(find.text('YouTube'));
      await tester.pump();
      expect(picked, isTrue);
    });
  });

  group('search results', () {
    testWidgets('a blank query invites you to type', (tester) async {
      await tester.pumpWidget(_app(const YouTubeSearchResults(query: '')));
      await tester.pump();

      expect(find.text('Type to search YouTube.'), findsOneWidget);
      expect(youtube.queries, isEmpty);
    });

    testWidgets('shows a spinner, then the tracks with artist and length', (tester) async {
      final reply = Completer<List<BaseItemDto>>();
      youtube.onSearch = (_) => reply.future;

      await tester.pumpWidget(_app(const YouTubeSearchResults(query: 'daft')));
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      reply.complete([
        _track('aaaaaaaaaaa', 'One More Time', 'Daft Punk'),
        _track('bbbbbbbbbbb', 'Aerodynamic', 'Daft Punk'),
      ]);
      await tester.pump();

      expect(find.text('One More Time'), findsOneWidget);
      expect(find.text('Aerodynamic'), findsOneWidget);
      expect(find.text('Daft Punk'), findsNWidgets(2));
      expect(find.text('2:05'), findsNWidgets(2));
    });

    testWidgets('typing is debounced, so a burst of keystrokes is one search', (tester) async {
      youtube.onSearch = (_) async => [_track('aaaaaaaaaaa', 'X', 'Y')];
      var query = 'a';
      late StateSetter set;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return YouTubeSearchResults(query: query, debounce: const Duration(milliseconds: 300));
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1)); // the first query fires at once

      for (final q in ['da', 'daf', 'daft']) {
        set(() => query = q);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 400));

      expect(youtube.queries, ['a', 'daft']);
    });

    testWidgets('no results is said plainly', (tester) async {
      youtube.onSearch = (_) async => const [];

      await tester.pumpWidget(_app(const YouTubeSearchResults(query: 'zzzz')));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(find.text('No results.'), findsOneWidget);
    });

    testWidgets('a failure names what failed, shows the friendly explanation, and can be retried', (tester) async {
      var attempts = 0;
      youtube.onSearch = (_) async {
        attempts++;
        if (attempts == 1) {
          throw const UploaderException(
            'YouTube is asking this server to prove it isn\'t a bot.',
            source: ErrorSource.ytdlp,
            code: 'youtube_blocked',
            detail: 'Sign in to confirm you\'re not a bot',
          );
        }
        return [_track('aaaaaaaaaaa', 'Recovered', 'Artist')];
      };

      await tester.pumpWidget(_app(const YouTubeSearchResults(query: 'x')));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(find.text('Problem: yt-dlp'), findsOneWidget);
      expect(find.textContaining('prove it isn\'t a bot'), findsOneWidget);
      expect(find.textContaining('Sign in to confirm'), findsNothing, reason: 'technical detail stays out of the UI');

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Recovered'), findsOneWidget);
      expect(attempts, 2);
    });

    testWidgets('a connection failure is labelled as such', (tester) async {
      youtube.onSearch = (_) async =>
          throw const UploaderException('Couldn\'t connect.', source: ErrorSource.connection);

      await tester.pumpWidget(_app(const YouTubeSearchResults(query: 'x')));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();

      expect(find.text('Problem: Connection'), findsOneWidget);
    });

    testWidgets('only the newest search is shown if answers arrive out of order', (tester) async {
      final slow = Completer<List<BaseItemDto>>();
      youtube.onSearch = (q) => q == 'old' ? slow.future : Future.value([_track('bbbbbbbbbbb', 'Fresh result', 'A')]);
      var query = 'old';
      late StateSetter set;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return YouTubeSearchResults(query: query, debounce: Duration.zero);
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      set(() => query = 'new');
      await tester.pump(); // builds, and starts the (zero-length) debounce timer
      await tester.pump(const Duration(milliseconds: 50)); // lets it fire

      slow.complete([_track('aaaaaaaaaaa', 'Stale result', 'A')]);
      await tester.pump();

      expect(find.text('Fresh result'), findsOneWidget);
      expect(find.text('Stale result'), findsNothing);
    });
  });

  group('track rows', () {
    testWidgets('via the uploader a row offers "add to server library", not a local download', (tester) async {
      bool played = false;
      await tester.pumpWidget(
        _app(
          YouTubeTrackTile(
            track: _track('aaaaaaaaaaa', 'Song', 'Artist'),
            onPlay: () => played = true,
            onDiscover: () {},
          ),
        ),
      );

      expect(find.byTooltip('Add to server library'), findsOneWidget);
      expect(find.byTooltip('Start discover queue'), findsOneWidget);

      await tester.tap(find.text('Song'));
      expect(played, isTrue);
    });
  });

  group('when YouTube is not set up', () {
    testWidgets('the tab explains why instead of showing an empty page', (tester) async {
      availability.status.value = const YouTubeStatus();
      await tester.pumpWidget(_app(const YouTubeSetupView()));

      expect(find.text('YouTube isn\'t set up yet'), findsOneWidget);
      expect(find.text('Use an uploader'), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
    });

    testWidgets('every reason is listed', (tester) async {
      availability.status.value = const YouTubeStatus(
        uploaderWanted: true,
        uploader: UploaderCapabilities(
          state: UploaderState.unauthorized,
          problem: 'The uploader didn\'t accept this device\'s token.',
        ),
      );
      await tester.pumpWidget(_app(const YouTubeSetupView()));

      expect(find.textContaining('didn\'t accept this device\'s token'), findsOneWidget);
    });

    testWidgets('updates by itself when things change', (tester) async {
      availability.status.value = const YouTubeStatus();
      await tester.pumpWidget(_app(const YouTubeSetupView()));
      expect(find.textContaining('isn\'t set up on this computer'), findsOneWidget);

      availability.status.value = const YouTubeStatus(
        uploaderWanted: true,
        uploader: UploaderCapabilities(state: UploaderState.unreachable, problem: 'Couldn\'t find that server.'),
      );
      await tester.pump();

      expect(find.textContaining('Couldn\'t find that server'), findsOneWidget);
    });
  });

  group('availability as seen by widgets', () {
    test('the provider follows the availability status', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(youTubeAvailableProvider), isFalse);

      availability.status.value = const YouTubeStatus(source: YouTubeSource.local, localReady: true);
      expect(container.read(youTubeAvailableProvider), isTrue);

      availability.status.value = const YouTubeStatus();
      expect(container.read(youTubeAvailableProvider), isFalse);
    });

    test('isYouTubeAvailable reads the same truth for non-widget code', () {
      availability.status.value = const YouTubeStatus(source: YouTubeSource.uploader);
      expect(isYouTubeAvailable, isTrue);
      availability.status.value = const YouTubeStatus();
      expect(isYouTubeAvailable, isFalse);
    });
  });
}
