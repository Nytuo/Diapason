import 'dart:async';
import 'dart:io';

import 'package:diapason/screens/uploader_settings_screen.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import '../test/support/fake_ytdlp.dart';
import 'support/harness.dart';

void main() {
  installHarness();

  group('the uploader', () {
    UploaderClient client() => GetIt.instance<UploaderClient>();

    Future<void> openUploader(WidgetTester tester) async {
      GlobalSnackbar.navigatorState!.pushNamed(UploaderSettingsScreen.routeName);
      await tester.settle();
    }

    testApp('settings: a wrong token is explained', (tester) async {
      await launch(tester);
      await openUploader(tester);

      await tester.enterText(find.widgetWithText(TextField, 'Sidecar address'), uploader.baseUrl.toString());
      await tester.enterText(find.widgetWithText(TextField, 'Token'), 'not-the-token');
      await tester.ensureVisible(find.text('Test connection'));
      await tester.tap(find.text('Test connection'));
      await tester.waitUntil(() => uploader.calls('/api/v1/capabilities').isNotEmpty, seconds: 15, what: 'the probe');
      await tester.settle();

      expect(find.textContaining('token'), findsWidgets);
      expect(find.textContaining('Connected'), findsNothing);
    }, timeout: slow);

    testApp('settings: the right token connects, saves, and reports what the server can do', (tester) async {
      await launch(tester);
      await openUploader(tester);

      await tester.enterText(find.widgetWithText(TextField, 'Sidecar address'), uploader.baseUrl.toString());
      await tester.enterText(find.widgetWithText(TextField, 'Token'), uploader.token);
      await tester.ensureVisible(find.text('Test connection'));
      await tester.tap(find.text('Test connection'));
      await tester.waitFor(find.textContaining('YouTube via yt-dlp is available'), seconds: 15);
      expect(find.textContaining('2099.01.01'), findsWidgets);

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.settle();
      expect(FinampSettingsHelper.finampSettings.uploaderUrl, uploader.baseUrl.toString());
      expect(FinampSettingsHelper.finampSettings.uploaderToken, uploader.token);
      expect(
        uploader.requests
            .where((r) => r.path.startsWith('/api'))
            .every(
              (r) =>
                  r.headers['authorization'] == 'Bearer ${uploader.token}' ||
                  r.headers['authorization'] == 'Bearer not-the-token',
            ),
        isTrue,
        reason: 'every call carries a bearer token, never anything else',
      );
    }, timeout: slow);

    testApp('settings: "Allow another device to pair" opens the pairing window on the server', (tester) async {
      await launch(tester);
      await openUploader(tester);
      await tester.ensureVisible(find.text('Allow another device to pair'));
      await tester.tap(find.text('Allow another device to pair'));
      await tester.waitUntil(() => uploader.pairingOpen, seconds: 15, what: 'the server opening its pairing window');
    }, timeout: slow);

    testApp('with the uploader on, YouTube shows up and searches go through the server', (tester) async {
      await launch(tester);
      FinampSetters.setUploaderEnabled(true);
      await GetIt.instance<YouTubeAvailability>().refresh();
      await tester.settle();

      expect(GetIt.instance<YouTubeAvailability>().source, YouTubeSource.uploader);
      expect(find.text('YouTube'), findsWidgets);

      final youtube = GetIt.instance<YouTubeService>();
      final found = await youtube.search('daft punk');
      expect(found.first.name, 'Result for daft punk');
      expect(uploader.calls('/api/v1/ytdlp/search').last.uri.queryParameters['q'], 'daft punk');
      expect((await youtube.homeShelves(refresh: true)).map((s) => s.title), contains('Hits on YouTube'));
      final stream = await youtube.streamUrl(found.first);
      expect(stream!.url.path, '/api/v1/ytdlp/stream/aaaaaaaaaaa');
      expect(stream.headers['Authorization'], 'Bearer ${uploader.token}');
    }, timeout: slow);

    testApp('"add to server library" has the server fetch the track and reports success', (tester) async {
      await launch(tester);
      final result = await client().ytDownloadToLibrary(
        'aaaaaaaaaaa',
        artist: 'Mock Artist',
        pollInterval: const Duration(milliseconds: 50),
      );

      expect(result.ok, isTrue);
      expect(uploader.downloads.single['artist'], 'Mock Artist');
    }, timeout: slow);

    testApp('a download the server cannot do says why and blames yt-dlp, not the app', (tester) async {
      await launch(tester);
      uploader.jobError = 'YouTube wants proof you are human.';
      final result = await client().ytDownloadToLibrary('bbbbbbbbbbb', pollInterval: const Duration(milliseconds: 50));
      uploader.jobError = null;

      expect(result.ok, isFalse);
      expect(result.message, contains('human'));
    }, timeout: slow);

    testApp('files are uploaded once; sending the same one again is a duplicate', (tester) async {
      await launch(tester);
      final file = File('${scratch.path}/upload.mp3')..writeAsBytesSync(List.generate(900, (i) => 32 + i % 90));

      final first = await client().uploadFile(file, artist: 'Mock Artist', album: 'Mock Album', title: 'Upload');
      expect(first.ok, isTrue);
      expect(uploader.uploads.single['title'], 'Upload');
      final second = await client().uploadFile(file, title: 'Upload');
      expect(second.duplicate, isTrue);
      expect(uploader.uploads, hasLength(1));
    }, timeout: slow);

    testApp('the server going away turns YouTube off again and the app says the uploader is unreachable', (
      tester,
    ) async {
      await launch(tester);
      await uploader.stop();
      await GetIt.instance<YouTubeAvailability>().refresh();
      await tester.settle();

      expect(GetIt.instance<YouTubeAvailability>().source, YouTubeSource.none);
      final caps = await client().capabilities();
      expect(caps.state, UploaderState.unreachable);
      expect(find.text('YouTube'), findsNothing);

      FinampSetters.setUploaderEnabled(false);
    }, timeout: slow);
  });

  group('YouTube appears only when it can work', () {
    testApp('with no yt-dlp and no uploader there is no YouTube anywhere', (tester) async {
      await launch(tester);
      await GetIt.instance<LocalYtDlpService>().refresh();
      await GetIt.instance<YouTubeAvailability>().refresh();
      await tester.settle();

      expect(GetIt.instance<YouTubeAvailability>().source, YouTubeSource.none);
      expect(find.text('YouTube'), findsNothing, reason: 'no tab, no switch');
    });

    testApp('pointing the app at a working yt-dlp makes the YouTube tab show up', (tester) async {
      await launch(tester);
      final local = GetIt.instance<LocalYtDlpService>();

      await local.saveConfig(YtDlpConfig()..customBinaryPath = fakeYtDlp.path);
      await GetIt.instance<YouTubeAvailability>().refresh();
      await tester.settle();

      expect(GetIt.instance<YouTubeAvailability>().source, YouTubeSource.local);
      expect(find.text('YouTube'), findsWidgets);
    }, skip: !FakeYtDlp.supported);

    testApp('and it disappears again when yt-dlp goes away', (tester) async {
      await launch(tester);
      final local = GetIt.instance<LocalYtDlpService>();

      await local.saveConfig(YtDlpConfig()..customBinaryPath = '${scratch.path}/gone');
      await GetIt.instance<YouTubeAvailability>().refresh();
      await tester.settle();

      expect(GetIt.instance<YouTubeAvailability>().source, YouTubeSource.none);
      expect(find.text('YouTube'), findsNothing);
    }, skip: !FakeYtDlp.supported);
  });
}
