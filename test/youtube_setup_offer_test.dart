import 'package:diapason/components/YtDlp/youtube_setup_view.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/testing.dart';

import 'support/fake_ytdlp.dart';
import 'support/test_env.dart';

/// The one-time "set up YouTube on this computer?" offer on desktop. Unprompted dialogs are only
/// acceptable if they are rare, dismissible for good, and never shown to people who don't need them.
/// (That it IS shown when it should be is checked end to end in integration_test/subsonic_flow_test.dart.)
void main() {
  late TestEnv env;
  late LocalYtDlpService local;
  late YouTubeAvailability availability;

  Future<void> offer(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const Scaffold();
          },
        ),
      ),
    );
    await tester.runAsync(() => offerYtDlpSetupIfNeeded(context).timeout(const Duration(seconds: 8), onTimeout: () {}));
    await tester.pump();
  }

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    YtDlpPaths.searchDirsOverride = [];
    YtDlpPaths.execBlockedReason = null;
    local = LocalYtDlpService();
    local.config.value = YtDlpConfig()..customBinaryPath = '${env.dir.path}/not-there';
    availability = YouTubeAvailability();
    GetIt.instance
      ..registerSingleton<LocalYtDlpService>(local)
      ..registerSingleton<UploaderClient>(
        UploaderClient(httpClient: MockClient((_) async => throw const SocketException('down'))),
      )
      ..registerSingleton<YouTubeAvailability>(availability);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    YtDlpPaths.searchDirsOverride = null;
    await env.dispose();
  });

  testWidgets('never shown again after "Don\'t ask again"', (tester) async {
    local.config.value = YtDlpConfig()
      ..customBinaryPath = '${env.dir.path}/not-there'
      ..promptDismissed = true;
    await tester.runAsync(() => local.refresh());

    await offer(tester);

    expect(find.text('Set up YouTube on this computer'), findsNothing);
  });

  testWidgets('not shown when yt-dlp already works', (tester) async {
    final fake = await tester.runAsync(() => FakeYtDlp.create(env.dir));
    local.config.value = YtDlpConfig()..customBinaryPath = fake!.path;
    await tester.runAsync(() => local.refresh());
    expect(local.status.value.isReady, isTrue);

    await offer(tester);

    expect(find.text('Set up YouTube on this computer'), findsNothing);
  }, skip: !FakeYtDlp.supported);

  testWidgets('not shown to someone who has pointed the app at an uploader that is merely down', (tester) async {
    await tester.runAsync(() async {
      env.updateSettings((s) {
        s.uploaderUrl = 'http://192.168.1.10:8688';
        s.uploaderYtProxy = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 100)); // let Hive finish writing
    });
    await tester.runAsync(() => local.refresh());

    await offer(tester);

    expect(find.text('Set up YouTube on this computer'), findsNothing);
  });
}
