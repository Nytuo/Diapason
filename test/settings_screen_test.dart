import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/screens/settings_screen.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/utils/platform_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/test_env.dart';

final searchField = find.widgetWithText(TextField, 'Search settings');

Future<void> pumpSettings(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 3000));
  // The app has the settings stream running before any screen is built; do the same here.
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(finampSettingsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routes: {
          for (final r in ['/settings/uploader', '/settings/ytdlp', '/settings/storage'])
            r: (_) => Scaffold(body: Text('page $r')),
        },
        home: const SettingsScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    GetIt.instance.registerSingleton<BackendRegistry>(BackendRegistry());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await env.dispose();
  });

  testWidgets('settings are grouped into sections', (tester) async {
    await pumpSettings(tester);

    for (final section in [
      'Library & sources',
      'Online music',
      'Playback',
      'Appearance & home',
      'Behaviour',
      'Storage & diagnostics',
    ]) {
      expect(find.text(section), findsOneWidget, reason: section);
    }
  });

  testWidgets('YouTube and the uploader are findable under Online music', (tester) async {
    await pumpSettings(tester);

    expect(find.text('YouTube (yt-dlp)'), findsOneWidget);
    expect(find.text('Uploader'), findsOneWidget);
    expect(find.text('Scrobbling'), findsOneWidget);
  });

  testWidgets('Jellyfin-only entries stay hidden without a Jellyfin source', (tester) async {
    await pumpSettings(tester);

    expect(find.text('Radio'), findsNothing);
    expect(find.textContaining('Client certificate'), findsNothing);
  });

  group('searching the settings', () {
    testWidgets('narrows the list to matching entries, by name or by keyword', (tester) async {
      await pumpSettings(tester);

      await tester.enterText(searchField, 'cache');
      await tester.pump();

      expect(find.text('Storage & logs'), findsOneWidget);
      expect(find.text('Stream cache'), findsOneWidget);
      expect(find.text('Equalizer'), findsNothing);
      expect(find.text('Playback'), findsNothing, reason: 'sections with no match disappear');
    });

    testWidgets('finds things by what they do, not just their title', (tester) async {
      await pumpSettings(tester);

      await tester.enterText(searchField, 'wifi');
      await tester.pump();
      // "Wi-Fi only" lives inside the uploader screen; its entry is findable by that keyword.
      expect(find.text('Uploader'), findsOneWidget);

      await tester.enterText(searchField, 'yt-dlp');
      await tester.pump();
      expect(find.text('YouTube (yt-dlp)'), findsOneWidget);
    });

    testWidgets('typing a section name shows the whole section', (tester) async {
      await pumpSettings(tester);

      await tester.enterText(searchField, 'online music');
      await tester.pump();

      expect(find.text('YouTube (yt-dlp)'), findsOneWidget);
      expect(find.text('Uploader'), findsOneWidget);
      expect(find.text('Scrobbling'), findsOneWidget);
    });

    testWidgets('every word must match', (tester) async {
      await pumpSettings(tester);

      await tester.enterText(searchField, 'youtube cookies');
      await tester.pump();
      expect(find.text('YouTube (yt-dlp)'), findsOneWidget);

      await tester.enterText(searchField, 'youtube zebra');
      await tester.pump();
      expect(find.text('YouTube (yt-dlp)'), findsNothing);
    });

    testWidgets('says so when nothing matches, and clearing brings everything back', (tester) async {
      await pumpSettings(tester);

      await tester.enterText(searchField, 'qwertyuiop');
      await tester.pump();
      expect(find.textContaining('No settings match'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(find.textContaining('No settings match'), findsNothing);
      expect(find.text('Playback'), findsOneWidget);
    });
  });

  group('opening a settings page', () {
    for (final (label, route) in [
      ('YouTube (yt-dlp)', '/settings/ytdlp'),
      ('Uploader', '/settings/uploader'),
      ('Storage & logs', '/settings/storage'),
    ]) {
      testWidgets('$label goes to $route', (tester) async {
        await pumpSettings(tester);

        await tester.tap(find.text(label));
        await tester.pumpAndSettle();

        expect(find.text('page $route'), findsOneWidget);
      });
    }
  });

  group('entries that depend on your sources', () {
    testWidgets('a Jellyfin server adds its libraries, radio and playback reporting', (tester) async {
      GetIt.instance<BackendRegistry>().register(_Fake('jf-1', MediaSourceKind.jellyfin));

      await pumpSettings(tester);

      expect(find.text('Radio'), findsOneWidget);
      expect(find.text('Playback Reporting & Play On'), findsOneWidget);
    });

    testWidgets('transcoding shows up only when some source can transcode', (tester) async {
      GetIt.instance<BackendRegistry>().register(_Fake('local', MediaSourceKind.local));
      await pumpSettings(tester);
      expect(find.text('Transcoding'), findsNothing);

      GetIt.instance<BackendRegistry>().register(_Fake('sub', MediaSourceKind.subsonic, transcoding: true));
      await pumpSettings(tester);
      expect(find.text('Transcoding'), findsOneWidget);
    });
  });

  group('Discord Rich Presence is easy to find', () {
    testWidgets('a switch in Playback on desktop', (tester) async {
      await pumpSettings(tester);

      expect(find.text('Discord RPC'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
    }, skip: !isDesktop);

    testWidgets('and findable by searching "discord"', (tester) async {
      await pumpSettings(tester);

      await tester.enterText(searchField, 'discord');
      await tester.pump();

      expect(find.text('Discord RPC'), findsOneWidget);
      expect(find.text('Equalizer'), findsNothing);
    }, skip: !isDesktop);
  });
}

class _Fake implements MediaBackend {
  _Fake(String id, MediaSourceKind kind, {bool transcoding = false})
    : config = MediaSourceConfig(sourceId: id, kind: kind, name: id),
      capabilities = BackendCapabilities(transcoding: transcoding);

  @override
  final MediaSourceConfig config;
  @override
  final BackendCapabilities capabilities;
  @override
  String get sourceId => config.sourceId;

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
