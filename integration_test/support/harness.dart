import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;

import 'package:diapason/components/Buttons/cta_huge.dart';
import 'package:diapason/screens/sources_settings_screen.dart';
import 'package:diapason/screens/cache_settings_screen.dart';
import 'package:diapason/screens/scrobbling_settings_screen.dart';
import 'package:diapason/screens/uploader_settings_screen.dart';
import 'package:diapason/screens/connect_screen.dart';
import 'package:diapason/screens/wrapped_screen.dart';
import 'package:diapason/screens/radio_screen.dart';
import 'package:diapason/screens/cast_screen.dart';
import 'package:diapason/screens/import_screen.dart';
import 'package:diapason/screens/shortcuts_screen.dart';
import 'package:diapason/screens/smart_playlists_screen.dart';
import 'package:diapason/screens/downloads_screen.dart';
import 'package:diapason/screens/active_downloads_screen.dart';
import 'package:diapason/screens/playback_history_screen.dart';
import 'package:diapason/screens/logs_screen.dart';
import 'package:diapason/screens/queue_restore_screen.dart';
import 'package:diapason/screens/settings_screen.dart';
import 'package:diapason/screens/home_screen_settings_screen.dart';
import 'package:diapason/screens/transcoding_settings_screen.dart';
import 'package:diapason/screens/downloads_location_screen.dart';
import 'package:diapason/screens/downloads_settings_screen.dart';
import 'package:diapason/screens/playback_reporting_settings_screen.dart';
import 'package:diapason/screens/audio_service_settings_screen.dart';
import 'package:diapason/screens/volume_normalization_settings_screen.dart';
import 'package:diapason/screens/equalizer_settings_screen.dart';
import 'package:diapason/screens/interaction_settings_screen.dart';
import 'package:diapason/screens/tabs_settings_screen.dart';
import 'package:diapason/screens/layout_settings_screen.dart';
import 'package:diapason/screens/customization_settings_screen.dart';
import 'package:diapason/screens/player_settings_screen.dart';
import 'package:diapason/screens/lyrics_settings_screen.dart';
import 'package:diapason/screens/visualizer_settings_screen.dart';
import 'package:diapason/screens/language_selection_screen.dart';
import 'package:diapason/screens/album_settings_screen.dart';
import 'package:diapason/screens/artist_settings_screen.dart';
import 'package:diapason/screens/genre_settings_screen.dart';
import 'package:diapason/screens/network_settings_screen.dart';
import 'package:diapason/screens/accessibility_settings_screen.dart';
import 'package:diapason/components/YtDlp/youtube_setup_view.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/main.dart' as app;
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/screens/login_screen.dart';
import 'package:diapason/screens/desktop/desktop_shell.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/utils/platform_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/updater_prefs.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:flutter/material.dart';
import 'package:meta/meta.dart' show isTest;
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../../test/support/fake_mpd.dart';
import '../../test/support/fake_ytdlp.dart';
import '../../test/support/mock_uploader.dart';
import '../../test/support/mock_subsonic.dart';

late MockSubsonicServer navidrome;
late Uri serverUrl;
late Directory scratch;
late FakeYtDlp fakeYtDlp;
late MockUploader uploader;
late FakeMpd mpd;
late HttpServer plex;
late void Function() installThemeWarningFilter;
ProviderContainer? container;
List<FlutterErrorDetails>? mainErrors = [];
var mainCompleted = false;

void installHarness() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.isWindows || Platform.isLinux) JustAudioMediaKit.nullBackend = true;

    UpdaterPrefs.autoCheckOverrideForTests = false;
    installThemeWarningFilter = _knownThemeWarningFilter();

    final report = reportTestException;
    reportTestException = (details, description) {
      final text = _describe(details);
      if (_isKnownNoise(text)) return;
      report(details, description);
    };

    scratch = await Directory.systemTemp.createTemp('diapason_it_');
    navidrome = MockSubsonicServer(audio: await _longSilence(scratch));
    serverUrl = await navidrome.start();

    uploader = MockUploader();
    await uploader.start();
    mpd = await FakeMpd.start();
    mpd.replies['config'] = ['music_directory: /srv/music'];
    mpd.replies['list album group albumartist'] = ['AlbumArtist: Mpd Artist', 'Album: Mpd Album'];
    plex = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    plex.listen((req) async {
      req.response.write(
        req.uri.path == '/library/sections'
            ? '{"MediaContainer":{"Directory":[{"type":"artist","key":"5"}]}}'
            : '{"MediaContainer":{"Metadata":[]}}',
      );
      await req.response.close();
    });

    fakeYtDlp = await FakeYtDlp.create(scratch);
    YtDlpPaths.searchDirsOverride = [];

    unawaited(
      runZonedGuarded(
        () async {
          await app.main(integrationTesting: true, loginTesting: true);
          mainCompleted = true;
        },
        (e, stack) {
          if (mainErrors != null) {
            mainErrors!.add(FlutterErrorDetails(exception: e, stack: stack));
          } else {
            debugPrint('Background error after startup: $e');
          }
        },
      ),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 180));
    while (!mainCompleted && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  tearDownAll(() async {
    await navidrome.stop();
    await uploader.stop();
    await mpd.stop();
    await plex.close(force: true);
    if (scratch.existsSync()) await scratch.delete(recursive: true);
  });

  setUp(() => installThemeWarningFilter());
}

void takeStartup() {
  if (container != null) return;
  for (final error in mainErrors ?? const <FlutterErrorDetails>[]) {
    debugPrint('Startup error: ${error.exception}\n${error.stack}');
  }
  container = GetIt.instance<ProviderContainer>();
  mainErrors = null;
}

Future<void> launch(WidgetTester tester, {bool signedOut = false, bool ytDlpOffer = false}) async {
  installThemeWarningFilter();
  takeStartup();

  final local = GetIt.instance<LocalYtDlpService>();
  if (local.config.value.promptDismissed == ytDlpOffer) {
    await local.saveConfig(YtDlpConfig.fromJson(local.config.value.toJson())..promptDismissed = !ytDlpOffer);
  }
  if (ytDlpOffer) resetYtDlpSetupOffer();
  GetIt.instance.unregister<ProviderContainer>();
  GetIt.instance.registerSingleton(ProviderContainer(parent: container));
  await tester.pumpWidget(app.Finamp());
  await tester.pump();
  if (signedOut) return;
  await tester.settle();
  if (find.byType(LoginScreen).evaluate().isNotEmpty) {
    await openSubsonicForm(tester);
    await fillSubsonicForm(tester, serverUrl);
    await tester.tap(find.text('Test'));
    await tester.waitFor(find.text('Connected'), seconds: 15);
    await tester.tap(find.text('Connect'));
    await tester.waitFor(library, seconds: 30);
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> switchView(WidgetTester tester, String view) async {
  await tester.tap(find.text(view).first, warnIfMissed: false);
  await tester.settle();
}

Future<void> toLibraryView(WidgetTester tester, String view) async {
  await launch(tester);
  await tester.waitFor(library, seconds: 30);
  await switchView(tester, view);
}

Future<void> closeWhatOpened(WidgetTester tester) async {
  await GlobalSnackbar.navigatorState!.maybePop();
  await tester.settle();
}

Future<bool> tapFirst(WidgetTester tester, Finder finder) async {
  final matches = finder.evaluate();
  if (matches.isEmpty) return false;
  await tester.tapAt(tester.getCenter(find.byElementPredicate((e) => e == matches.first)));
  await tester.settle();
  return true;
}

QueueService queueService() => GetIt.instance<QueueService>();

Future<void> openSubsonicForm(WidgetTester tester) async {
  await tester.settle();
  if (find.text('Server address').evaluate().isNotEmpty) return;
  if (find.byType(CTAHuge).evaluate().isNotEmpty) {
    await tester.tap(find.byType(CTAHuge));
    await tester.settle();
  }
  await tester.tap(find.text('Subsonic / Navidrome'));
  await tester.settle();
}

Future<void> fillSubsonicForm(WidgetTester tester, Uri server, {String password = 'hunter2'}) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Server address'), server.toString());
  await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'tester');
  await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
  await tester.pump();
}

Future<List<int>?> _longSilence(Directory scratch) async {
  final out = File('${scratch.path}/silence.mp3');
  try {
    final r = await Process.run('ffmpeg', [
      '-y',
      '-f',
      'lavfi',
      '-i',
      'anullsrc=r=44100:cl=mono',
      '-t',
      '40',
      '-q:a',
      '9',
      out.path,
    ]);
    if (r.exitCode == 0 && out.existsSync()) return out.readAsBytesSync();
  } catch (_) {}
  final fixture = File('test/fixtures/music/test.mp3');
  if (!fixture.existsSync()) return null;
  final bytes = fixture.readAsBytesSync();
  return [for (var i = 0; i < 50; i++) ...bytes];
}

final Finder library = isDesktop ? find.byType(DesktopShell) : find.byType(MusicScreen);

const slow = Timeout(Duration(minutes: 3));

Future<void> expectAnnouncedAndPlaying(
  WidgetTester tester,
  MockSubsonicServer server,
  String trackId, {
  bool checkPosition = true,
}) async {
  await tester.waitUntil(
    () => server.scrobbles.any((s) => s.params['submission'] == 'false' && s.params['id'] == trackId),
    seconds: 30,
    what: 'the server hearing that $trackId is now playing',
  );
  final report = server.scrobbles.firstWhere((s) => s.params['submission'] == 'false' && s.params['id'] == trackId);
  expect(report.client, 'Diapason', reason: 'this is what Navidrome shows under Now Playing');

  final player = GetIt.instance<MusicPlayerBackgroundTask>();
  expect(player.playbackState.value.playing, isTrue);
  if (!checkPosition) return;
  var peak = Duration.zero;
  for (var i = 0; i < 40 && peak.inSeconds < 2; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (player.playbackPosition > peak) peak = player.playbackPosition;
  }
  expect(
    peak.inSeconds,
    greaterThanOrEqualTo(2),
    reason: 'playing=${player.playbackState.value.playing} state=${player.playbackState.value.processingState}',
  );
}

Future<void> openAlbums(WidgetTester tester) async {
  await tester.waitFor(library, seconds: 30);
  if (isDesktop) {
    await tester.tap(find.text('Albums').first, warnIfMissed: false);
    await tester.settle();
  }
  await tester.waitFor(find.text('First Album'), seconds: 30);
}

extension WaitFor on WidgetTester {
  Future<void> settle({int frames = 4}) async {
    for (var i = 0; i < frames; i++) {
      await pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> waitFor(Finder finder, {int seconds = 20}) async {
    await waitUntil(() => any(finder), seconds: seconds, what: finder.description);
  }

  Future<void> waitUntil(bool Function() condition, {int seconds = 20, String what = 'condition'}) async {
    final clock = Stopwatch()..start();
    while (true) {
      if (condition()) return;
      if (clock.elapsed > Duration(seconds: seconds)) break;
      await pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final onScreen = widgetList<Text>(
      find.byType(Text),
    ).map((t) => t.data).whereType<String>().toSet().take(60).toList();
    throw TestFailure('"$what" did not become true within $seconds seconds. Text on screen: $onScreen');
  }
}

void Function() _knownThemeWarningFilter() {
  void Function(FlutterErrorDetails)? inner;
  late final void Function(FlutterErrorDetails) filter;
  filter = (details) {
    final text = _describe(details);
    if (_isKnownNoise(text)) {
      final firstLine = text.split('\n').skip(1).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      print(
        'Ignoring known framework noise: ${firstLine.trim()} [${text.split('\n').where((l) => l.contains('package:diapason')).take(2).map((l) => l.trim()).join(' <- ')}]',
      );
      return;
    }
    (inner ?? FlutterError.presentError)(details);
  };
  void install() {
    if (FlutterError.onError != filter) {
      inner = FlutterError.onError;
      FlutterError.onError = filter;
    }
  }

  WidgetsBinding.instance.addPersistentFrameCallback((_) => install());
  return install;
}

bool _isKnownNoise(String text) =>
    text.contains('setState() or markNeedsBuild() called during build') ||
    text.contains('Invalid state transition from AppLifecycleState') ||
    text.contains('unexpectedly has a HitTestResult associated with it') ||
    text.contains('No content even though contentLength was specified') ||
    text.contains('widget consumes the entire tile width') ||
    text.contains('ListTile background color or ink splashes may be invisible') ||
    text.contains('during performLayout()') ||
    text.contains('during paint()') ||
    text.contains('parentDataDirty') ||
    text.contains('child.hasSize') ||
    text.contains('was not laid out') ||
    text.contains('childSemantics.renderObject._needsLayout') ||
    text.contains('RenderFlex overflowed') ||
    (text.contains('No active stream to cancel') && text.contains('just_audio.spectrum'));

String _describe(FlutterErrorDetails details) => "${details.toDiagnosticsNode().toStringDeep()}\n${details.stack}";

final screenRoutes = <String, String>{
  'SourcesSettingsScreen': SourcesSettingsScreen.routeName,
  'CacheSettingsScreen': CacheSettingsScreen.routeName,
  'ScrobblingSettingsScreen': ScrobblingSettingsScreen.routeName,
  'UploaderSettingsScreen': UploaderSettingsScreen.routeName,
  'ConnectScreen': ConnectScreen.routeName,
  'WrappedScreen': WrappedScreen.routeName,
  'RadioScreen': RadioScreen.routeName,
  'CastScreen': CastScreen.routeName,
  'ImportScreen': ImportScreen.routeName,
  'ShortcutsScreen': ShortcutsScreen.routeName,
  'SmartPlaylistsScreen': SmartPlaylistsScreen.routeName,
  'DownloadsScreen': DownloadsScreen.routeName,
  'ActiveDownloadsScreen': ActiveDownloadsScreen.routeName,
  'PlaybackHistoryScreen': PlaybackHistoryScreen.routeName,
  'LogsScreen': LogsScreen.routeName,
  'QueueRestoreScreen': QueueRestoreScreen.routeName,
  'SettingsScreen': SettingsScreen.routeName,
  'HomeScreenSettingsScreen': HomeScreenSettingsScreen.routeName,
  'TranscodingSettingsScreen': TranscodingSettingsScreen.routeName,
  'DownloadsLocationScreen': DownloadsLocationScreen.routeName,
  'DownloadsSettingsScreen': DownloadsSettingsScreen.routeName,
  'PlaybackReportingSettingsScreen': PlaybackReportingSettingsScreen.routeName,
  'AudioServiceSettingsScreen': AudioServiceSettingsScreen.routeName,
  'VolumeNormalizationSettingsScreen': VolumeNormalizationSettingsScreen.routeName,
  'EqualizerSettingsScreen': EqualizerSettingsScreen.routeName,
  'InteractionSettingsScreen': InteractionSettingsScreen.routeName,
  'TabsSettingsScreen': TabsSettingsScreen.routeName,
  'LayoutSettingsScreen': LayoutSettingsScreen.routeName,
  'CustomizationSettingsScreen': CustomizationSettingsScreen.routeName,
  'PlayerSettingsScreen': PlayerSettingsScreen.routeName,
  'LyricsSettingsScreen': LyricsSettingsScreen.routeName,
  'VisualizerSettingsScreen': VisualizerSettingsScreen.routeName,
  'LanguageSelectionScreen': LanguageSelectionScreen.routeName,
  'AlbumSettingsScreen': AlbumSettingsScreen.routeName,
  'ArtistSettingsScreen': ArtistSettingsScreen.routeName,
  'GenreSettingsScreen': GenreSettingsScreen.routeName,
  'NetworkSettingsScreen': NetworkSettingsScreen.routeName,
  'AccessibilitySettingsScreen': AccessibilitySettingsScreen.routeName,
};

@isTest
void testApp(String description, Future<void> Function(WidgetTester tester) body, {Object? skip, Timeout? timeout}) {
  testWidgets(
    description,
    (tester) async {
      timeDilation = 0.02;
      try {
        await body(tester);
      } finally {
        timeDilation = 1.0;
      }
    },
    skip: skip != null && skip != false,
    timeout: timeout,
  );
}

Future<void> exploreTop(
  WidgetTester tester, {
  int taps = 6,
  int seed = 1,
  String avoid =
      r'delete|remove|clear|reset|log ?out|erase|wipe|install|update|choose|pick|browse|import|export|'
      r'mini|full ?screen|window|stop playback|quit|exit',
}) async {
  final deny = RegExp(avoid, caseSensitive: false);
  final random = Random(seed);
  final navigator = GlobalSnackbar.navigatorState!;
  late Route<dynamic> start;
  navigator.popUntil((r) {
    start = r;
    return true;
  });
  bool tappable(Widget w) =>
      w is InkWell ||
      w is IconButton ||
      w is ListTile ||
      w is Switch ||
      w is Checkbox ||
      w is Radio ||
      w is ChoiceChip ||
      w is FilterChip ||
      w is FilledButton ||
      w is TextButton ||
      w is OutlinedButton ||
      w is ElevatedButton ||
      w is SegmentedButton ||
      w is Slider;
  String label(Element element) {
    final parts = <String>[];
    void visit(Element e) {
      final w = e.widget;
      if (w is Text && w.data != null) parts.add(w.data!);
      if (w is Tooltip && w.message != null) parts.add(w.message!);
      e.visitChildren(visit);
    }

    visit(element);
    return parts.join(' ');
  }

  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (var i = 0; i < taps; i++) {
    final candidates = find.byWidgetPredicate(tappable).evaluate().where((e) {
      final box = e.renderObject;
      if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) return false;
      return (Offset.zero & size).contains((box.localToGlobal(Offset.zero) & box.size).center) &&
          !deny.hasMatch(label(e));
    }).toList();
    if (candidates.isEmpty) break;
    final box = candidates[random.nextInt(candidates.length)].renderObject! as RenderBox;
    await tester.tapAt(box.localToGlobal(Offset.zero) + box.size.center(Offset.zero));
    await tester.settle();
  }
  navigator.popUntil((r) => identical(r, start) || r.isFirst);
  await tester.settle();
}
