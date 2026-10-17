import 'package:diapason/screens/player_screen.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/harness.dart';

void main() {
  installHarness();

  group('every screen opens', () {


    final screens = screenRoutes;

    for (final entry in screens.entries) {
      testApp('${entry.key} opens and closes', (tester) async {
        await launch(tester);
        GlobalSnackbar.navigatorState!.pushNamed(entry.value);
        await tester.settle();
        expect(find.byType(Scaffold), findsWidgets);
        GlobalSnackbar.navigatorState!.pop();
        await tester.settle();
      }, timeout: slow);
    }

    testApp('the player screen opens with a track playing', (tester) async {
      await launch(tester);
      final queue = GetIt.instance<QueueService>();
      final source = QueueItemSource.rawId(
        type: QueueItemSourceType.unknown,
        name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
        id: 'player-test',
      );
      final item = (await GetIt.instance<AggregateBackend>().getItems(includeItemTypes: 'Audio')).take(2).toList();
      await queue.startPlayback(items: item, source: source, order: FinampPlaybackOrder.linear, startingIndex: 0);
      await tester.settle();

      GlobalSnackbar.navigatorState!.pushNamed(PlayerScreen.routeName);
      await tester.settle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));

      for (final label in ['Queue', 'Lyrics', 'Output']) {
        await tester.tap(find.text(label).first, warnIfMissed: false);
        await tester.settle();
        await GlobalSnackbar.navigatorState!.maybePop();
        await tester.settle();
        expect(find.byType(PlayerScreen), findsOneWidget, reason: 'back on the player after "$label"');
      }
      await tester.tap(find.byTooltip('Add to playlist').first, warnIfMissed: false);
      await tester.settle();
      await GlobalSnackbar.navigatorState!.maybePop();
      await tester.settle();

      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
      await queue.stopAndClearQueue();
    }, timeout: slow);
  });

  group('settings', () {
    testApp('open from the app, are grouped, and can be searched', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed('/settings');
      await tester.settle();

      expect(find.text('Online music'), findsOneWidget);
      expect(find.text('YouTube (yt-dlp)'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Search settings'), 'cache');
      await tester.settle();
      expect(find.text('Stream cache'), findsOneWidget);
      expect(find.text('Equalizer'), findsNothing);

      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
    });

    testApp('the YouTube page explains what is going on', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed('/settings/ytdlp');
      await tester.settle();

      expect(find.text('YouTube (yt-dlp)'), findsWidgets);
      expect(find.textContaining('yt-dlp'), findsWidgets);

      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
    });

    testApp('the storage page lists what the app keeps, with sizes', (tester) async {
      await launch(tester);
      GlobalSnackbar.navigatorState!.pushNamed('/settings/storage');
      await tester.settle();

      expect(find.text('Streamed tracks'), findsOneWidget);
      expect(find.text('Cover art'), findsOneWidget);
      expect(find.text('Log files'), findsOneWidget);
      expect(find.text('Log detail'), findsOneWidget);

      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
    });
  });
}
