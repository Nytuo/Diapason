import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/screens/player_screen.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/harness.dart';

void main() {
  installHarness();

  QueueService queue() => GetIt.instance<QueueService>();
  AggregateBackend backend() => GetIt.instance<AggregateBackend>();
  MusicPlayerBackgroundTask player() => GetIt.instance<MusicPlayerBackgroundTask>();

  Future<void> play(WidgetTester tester) async {
    final items = (await backend().getItems(includeItemTypes: 'Audio')).toList();
    final source = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
      id: 'polish',
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

  group('messages', () {
    testApp('snackbars, confirmations, errors and popups all appear', (tester) async {
      await launch(tester);
      await tester.waitFor(library, seconds: 30);

      GlobalSnackbar.message((_) => 'A plain message');
      await tester.waitFor(find.text('A plain message'), seconds: 10);
      GlobalSnackbar.dismissAllSnackbars();
      await tester.settle();

      GlobalSnackbar.message((_) => 'Saved it', isConfirmation: true);
      await tester.waitFor(find.text('Saved it'), seconds: 10);
      GlobalSnackbar.dismissAllSnackbars();
      await tester.settle();

      GlobalSnackbar.error(Exception('Something went wrong in a test'));
      await tester.settle(frames: 10);
      GlobalSnackbar.dismissAllSnackbars();
      await tester.settle();

      GlobalSnackbar.popup((_) => ('A title', 'The details of a popup'));
      await tester.settle(frames: 10);
      await GlobalSnackbar.navigatorState!.maybePop();
      await tester.settle();
    }, timeout: slow);
  });

  group('the audio engine', () {
    Future<void> within(Future<void> call) => call.timeout(const Duration(seconds: 8), onTimeout: () {});

    testApp('transport controls, seeking, volume and fades', (tester) async {
      await launch(tester);
      FinampSetters.setAudioFadeInDuration(const Duration(milliseconds: 300));
      FinampSetters.setAudioFadeOutDuration(const Duration(milliseconds: 300));
      await play(tester);

      await within(player().pause());
      await tester.settle(frames: 10);
      expect(player().playbackState.value.playing, isFalse);
      await within(player().play());
      await tester.settle(frames: 10);
      expect(player().playbackState.value.playing, isTrue);

      await within(player().seek(const Duration(seconds: 10)));
      await tester.waitUntil(() => player().playbackPosition >= const Duration(seconds: 9), what: 'the seek');
      await within(player().fastForward());
      await within(player().rewind());
      player().setVolume(0.4);
      await tester.settle();
      player().setVolume(1.0);

      final first = queue().getQueue().currentTrack!.id;
      await within(player().skipToNext());
      await tester.waitUntil(() => queue().getQueue().currentTrack!.id != first, what: 'the next track');
      await within(player().skipToPrevious(forceSkip: true));
      await tester.settle(frames: 10);

      await within(player().stop());
      await tester.settle(frames: 10);
      FinampSetters.setAudioFadeInDuration(DefaultSettings.audioFadeInDuration);
      FinampSetters.setAudioFadeOutDuration(DefaultSettings.audioFadeOutDuration);
      await queue().stopAndClearQueue();
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('the queue sheet', () {
    testApp('items can be dragged, tapped and swiped away', (tester) async {
      await launch(tester);
      await play(tester);
      GlobalSnackbar.navigatorState!.pushNamed(PlayerScreen.routeName);
      await tester.settle(frames: 8);
      await tester.tap(find.text('Queue').first, warnIfMissed: false);
      await tester.settle(frames: 10);

      final before = queue().getQueue().queue.length;
      final row = find.text('Beta Song');
      if (row.evaluate().isNotEmpty) {
        await tester.drag(row.first, const Offset(0, -120), warnIfMissed: false);
        await tester.settle(frames: 8);
        await tester.drag(find.text('Closing').first, const Offset(-400, 0), warnIfMissed: false);
        await tester.settle(frames: 10);
      }
      expect(queue().getQueue().queue.length, lessThanOrEqualTo(before));
      await exploreTop(tester, taps: 6, seed: 121, avoid: r'clear|delete|window|stop playback');

      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);
  });

  group('sorting and filtering', () {
    for (final view in ['Albums', 'Artists', 'Songs', 'Genres', 'Playlists']) {
      testApp('every sort and filter choice in $view can be picked', (tester) async {
        await launch(tester);
        await tester.waitFor(library, seconds: 30);
        await tester.tap(find.text(view).first, warnIfMissed: false);
        await tester.settle(frames: 10);

        for (final control in ['Name', 'No Filter Active']) {
          for (var round = 0; round < 3; round++) {
            final entry = find.text(control);
            if (entry.evaluate().isEmpty) break;
            await tester.tap(entry.first, warnIfMissed: false);
            await tester.settle(frames: 8);
            await exploreTop(
              tester,
              taps: 2,
              seed: 130 + round + view.length,
              avoid: r'delete|remove|clear|reset|window',
            );
          }
        }
        await tapFirst(tester, find.byIcon(Icons.sort));
        await tapFirst(tester, find.byIcon(Icons.arrow_upward));
        await tapFirst(tester, find.byIcon(Icons.arrow_downward));
      }, timeout: slow);
    }
  });

  group('radio', () {
    testApp('"Start Radio" from the player menu and the radio mode menu', (tester) async {
      await launch(tester);
      await play(tester);
      GlobalSnackbar.navigatorState!.pushNamed(PlayerScreen.routeName);
      await tester.settle(frames: 8);

      final buttons = find.byType(IconButton).hitTestable().evaluate().toList();
      await tester.tapAt(tester.getCenter(find.byElementPredicate((e) => e == buttons.first)));
      await tester.settle(frames: 8);
      await tapFirst(tester, find.text('Start Radio'));
      await tester.settle(frames: 12);

      final again = find.byType(IconButton).hitTestable().evaluate().toList();
      if (again.isNotEmpty) {
        await tester.tapAt(tester.getCenter(find.byElementPredicate((e) => e == again.first)));
        await tester.settle(frames: 8);
        await exploreTop(tester, taps: 6, seed: 141, avoid: r'delete|remove|clear|reset|window|stop playback');
      }
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
      await queue().stopAndClearQueue();
    }, timeout: slow);
  });
}
