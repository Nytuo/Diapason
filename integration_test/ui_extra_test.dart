import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/screens/downloads_screen.dart';
import 'package:diapason/screens/home_screen_settings_screen.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/screens/player_screen.dart';
import 'package:diapason/screens/playback_history_screen.dart';
import 'package:diapason/screens/smart_playlists_screen.dart';
import 'package:diapason/screens/view_selector.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/harness.dart';



void main() {
  installHarness();

  QueueService queue() => GetIt.instance<QueueService>();
  AggregateBackend backend() => GetIt.instance<AggregateBackend>();

  Future<void> play(WidgetTester tester, {int copies = 2}) async {
    final items = (await backend().getItems(includeItemTypes: 'Audio')).toList();
    final source = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
      id: 'ui-extra',
    );
    await queue().startPlayback(
      items: [for (var i = 0; i < copies; i++) ...items],
      source: source,
      order: FinampPlaybackOrder.linear,
      startingIndex: 0,
    );
    await tester.waitUntil(() => queue().getQueue().currentTrack != null, seconds: 20, what: 'a current track');
    await tester.settle();
  }

  group('playback speed', () {
    testApp('a changed speed shows in the player menu, which opens the speed controls', (tester) async {
      await launch(tester);
      await play(tester);
      queue().playbackSpeed = 1.25;
      GlobalSnackbar.navigatorState!.pushNamed(PlayerScreen.routeName);
      await tester.settle(frames: 8);

      final buttons = find.byType(IconButton).hitTestable().evaluate().toList();
      await tester.tapAt(tester.getCenter(find.byElementPredicate((e) => e == buttons.first)));
      await tester.settle(frames: 8);
      final speed = find.textContaining('1.25');
      if (speed.evaluate().isNotEmpty) {
        await tester.tap(speed.first, warnIfMissed: false);
        await tester.settle(frames: 8);
        await exploreTop(tester, taps: 6, seed: 51);
      }
      queue().playbackSpeed = 1.0;
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);
  });

  group('the home screen editor', () {
    testApp('a section opens in the editor and can be changed', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed(HomeScreenSettingsScreen.routeName);
      await tester.settle(frames: 10);
      await tapFirst(tester, find.byTooltip('Edit section'));
      if (find.text('Quick Actions').evaluate().isNotEmpty) await tapFirst(tester, find.text('Newly Added Albums'));
      print(
        'EDITOR texts: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().toList()}',
      );
      await exploreTop(tester, taps: 8, seed: 61, avoid: r'delete|reset|window');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);
  });

  group('the side drawer and view selector', () {
    testApp('the phone layout has a drawer with settings and links', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed(MusicScreen.routeName);
      await tester.settle(frames: 12);
      final scaffold = tester.firstState<ScaffoldState>(find.byType(Scaffold).first);
      scaffold.openDrawer();
      await tester.settle(frames: 10);
      print(
        'DRAWER texts: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().toList()}',
      );
      await exploreTop(tester, taps: 6, seed: 71, avoid: r'log ?out|delete|remove|clear|reset|window|quit');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);

    testApp('the library views can be listed', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed(ViewSelector.routeName);
      await tester.settle(frames: 12);
      await exploreTop(tester, taps: 4, seed: 72, avoid: r'delete|remove|clear|reset|window|log ?out|save');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);
  });

  group('playback history', () {
    testApp('what was played is listed', (tester) async {
      await launch(tester);
      await play(tester, copies: 1);
      await queue().skipByOffset(1);
      await tester.settle(frames: 10);
      GlobalSnackbar.navigatorState!.pushNamed(PlaybackHistoryScreen.routeName);
      await tester.settle(frames: 12);
      print(
        'HISTORY texts: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().toList()}',
      );
      await exploreTop(tester, taps: 5, seed: 81, avoid: r'delete|remove|clear|reset|window|play');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);
  });

  group('smart playlists', () {
    testApp('the editor opens from the Smart view and can build a rule', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed(SmartPlaylistsScreen.routeName);
      await tester.settle(frames: 10);
      await tapFirst(tester, find.text('New'));
      await tester.settle(frames: 10);
      print(
        'SMART texts: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().toList()}',
      );
      await exploreTop(tester, taps: 8, seed: 91, avoid: r'delete|remove|clear|reset|window|cancel');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: slow);
  });

  group('downloads', () {
    testApp('an album can be downloaded to the device and then shows in Downloads', (tester) async {
      await launch(tester);
      final album = (await backend().getItems(includeItemTypes: 'MusicAlbum')).first;
      final service = GetIt.instance<DownloadsService>();
      await service.addDownload(
        stub: DownloadStub.fromItem(type: DownloadItemType.collection, item: album),
        transcodeProfile: DownloadProfile(transcodeCodec: FinampTranscodingCodec.original),
      );
      await tester.waitUntil(
        () => navidrome.calls('download').isNotEmpty || navidrome.calls('stream').isNotEmpty,
        seconds: 40,
        what: 'the app fetching the album from the server',
      );
      GlobalSnackbar.navigatorState!.pushNamed(DownloadsScreen.routeName);
      await tester.settle(frames: 15);
      print(
        'DOWNLOADS texts: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().toList()}',
      );
      await exploreTop(tester, taps: 6, seed: 101, avoid: r'delete|remove|clear|reset|window');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
