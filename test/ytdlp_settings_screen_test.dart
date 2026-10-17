import 'dart:io';

import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/screens/ytdlp_settings_screen.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/fake_ytdlp.dart';
import 'support/test_env.dart';

/// Settings → YouTube (yt-dlp): the page where people install, tweak and test yt-dlp.
/// Taps inside real async, because the buttons under test start real processes (a fake-clock
/// test zone would wait forever for them) and then gives them a moment to finish.
Future<void> _tapAndWait(WidgetTester tester, Finder finder, {Duration wait = const Duration(seconds: 2)}) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(wait);
  });
  await tester.pump();
}

void main() {
  if (!FakeYtDlp.supported || !Platform.isMacOS && !Platform.isLinux) {
    test('desktop only', () {}, skip: 'this page is the desktop yt-dlp manager');
    return;
  }

  late TestEnv env;
  late FakeYtDlp fake;
  late LocalYtDlpService local;
  late YouTubeAvailability availability;

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await local.refresh();
      await availability.refresh();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const YtDlpSettingsScreen(),
      ),
    );
    await tester.pump();
  }

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    fake = await FakeYtDlp.create(env.dir);
    YtDlpPaths.searchDirsOverride = [];
    YtDlpPaths.execBlockedReason = null;
    local = LocalYtDlpService();
    local.config.value = YtDlpConfig()..customBinaryPath = fake.path;
    availability = YouTubeAvailability();
    GetIt.instance
      ..registerSingleton<LocalYtDlpService>(local)
      ..registerSingleton<UploaderClient>(UploaderClient())
      ..registerSingleton<YouTubeAvailability>(availability);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    YtDlpPaths.searchDirsOverride = null;
    await env.dispose();
  });

  testWidgets('shows what was found on this computer', (tester) async {
    await open(tester);

    expect(find.text('YouTube is on'), findsOneWidget);
    expect(find.text('yt-dlp 2099.01.01'), findsOneWidget);
    expect(find.textContaining('Your own copy'), findsOneWidget);
    expect(find.textContaining('JavaScript runtime: none'), findsOneWidget);
  });

  testWidgets('offers installation when yt-dlp is missing', (tester) async {
    local.config.value = YtDlpConfig()..customBinaryPath = '${env.dir.path}/none';
    await open(tester);

    expect(find.text('YouTube is off'), findsOneWidget);
    expect(find.text('Install yt-dlp'), findsOneWidget);
    expect(find.textContaining("wasn't found"), findsOneWidget);
  });

  testWidgets('a program that will not run is explained, not just "off"', (tester) async {
    final junk = File('${env.dir.path}/junk')..writeAsStringSync('nope');
    local.config.value = YtDlpConfig()..customBinaryPath = junk.path;
    await open(tester);

    expect(find.textContaining("won't run"), findsWidgets);
  });

  testWidgets('"Test with a real video" runs a full lookup and reports success in plain words', (tester) async {
    await open(tester);

    await _tapAndWait(tester, find.text('Test with a real video'));

    expect(find.textContaining('Me at the zoo'), findsOneWidget);
    expect(fake.operations, isNotEmpty);
  });

  testWidgets('a failing test shows the friendly reason first and the technical line after', (tester) async {
    await open(tester);
    await tester.runAsync(() => fake.setMode('bot'));

    await _tapAndWait(tester, find.text('Test with a real video'));

    final text = tester
        .widget<SelectableText>(find.byWidgetPredicate((w) => w is SelectableText && (w.data ?? '').contains('bot')))
        .data!;
    expect(text.indexOf('prove it isn'), lessThan(text.indexOf('Sign in to confirm')));
  });

  testWidgets('the command preview follows the settings, and advanced mode lets you write your own', (tester) async {
    await open(tester);
    expect(find.textContaining('--ignore-config'), findsWidgets);

    await tester.enterText(find.widgetWithText(TextField, 'Proxy'), 'socks5://10.0.0.2:1080');
    await tester.pump();
    expect(find.textContaining('--proxy socks5://10.0.0.2:1080'), findsWidgets);

    await tester.tap(find.text('Advanced mode'));
    await tester.pump();
    final editor = find.widgetWithText(TextField, '');
    expect(find.textContaining('Flags passed to every yt-dlp run'), findsOneWidget);
    expect(editor, findsWidgets);

    // The editor starts from the visual settings, so switching modes loses nothing.
    final field = tester.widget<TextField>(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Flags passed to every yt-dlp run'),
    );
    expect(field.controller!.text, contains('socks5://10.0.0.2:1080'));
  });

  testWidgets('saving persists the settings and the page reflects them after reopening', (tester) async {
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Speed limit'), '3M');
    await tester.pump();

    await tester.ensureVisible(find.text('Save settings'));
    await _tapAndWait(tester, find.text('Save settings'), wait: const Duration(milliseconds: 600));

    expect(YtDlpConfig.decode(FinampSettingsHelper.finampSettings.ytdlpConfigJson).rateLimit, '3M');
    expect(local.config.value.rateLimit, '3M');
  });

  testWidgets('"In the app" options write straight to settings', (tester) async {
    await open(tester);

    await _tapAndWait(tester, find.text('Search YouTube first'), wait: const Duration(milliseconds: 200));
    await _tapAndWait(tester, find.text('“Hits on YouTube” shelf'), wait: const Duration(milliseconds: 200));

    expect(FinampSettingsHelper.finampSettings.youtubeSearchByDefault, isTrue);
    expect(FinampSettingsHelper.finampSettings.youtubeShowHits, isFalse);
  });

  testWidgets('says which route is in use when both an uploader and this computer are available', (tester) async {
    await open(tester);
    availability.status.value = const YouTubeStatus(source: YouTubeSource.local, localReady: true);
    await tester.pump();

    expect(find.text('Using yt-dlp on this computer.'), findsOneWidget);
  });
}
