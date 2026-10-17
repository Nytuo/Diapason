import 'dart:async';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_slices.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/harness.dart';

void main() {
  installHarness();

  group('the play queue', () {
    final source = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
      id: 'test-source',
    );
    late QueueService queue;
    var tracks = <BaseItemDto>[];

    Future<void> prep(WidgetTester tester) async {
      await launch(tester);
      queue = GetIt.instance<QueueService>();
      if (tracks.isEmpty) {
        final some = (await GetIt.instance<AggregateBackend>().getItems(includeItemTypes: 'Audio')).take(2).toList();
        tracks = [...some, ...some];
      }
    }

    List<String?> names(List<FinampQueueItem> l) => l.map((i) => i.baseItem?.name).toList();
    int total() {
      final q = queue.getQueue();
      return q.previousTracks.length + (q.currentTrack == null ? 0 : 1) + q.nextUp.length + q.queue.length;
    }

    Future<void> fresh(WidgetTester tester) async {
      await queue.startPlayback(items: tracks, source: source, order: FinampPlaybackOrder.linear, startingIndex: 0);
      await tester.waitUntil(() => queue.getQueue().currentTrack != null, seconds: 15, what: 'a current track');
    }

    testApp('has tracks to play from the library', (tester) async {
      await prep(tester);
      expect(tracks.length, greaterThanOrEqualTo(2));
    });

    testApp('starting playback fills the queue with the first track current', (tester) async {
      await prep(tester);
      await fresh(tester);

      expect(total(), tracks.length);
      expect(queue.getQueue().currentTrack!.baseItem!.id, tracks.first.id);
      expect(queue.getQueue().previousTracks, isEmpty);
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
    }, timeout: slow);

    testApp('"add to end", "play next" and "next up" each add tracks', (tester) async {
      await prep(tester);
      await fresh(tester);

      await queue.addToQueue(PlayableSlice.simple([tracks.first], source));
      expect(total(), tracks.length + 1);

      await queue.addNext(PlayableSlice.simple([tracks.first], source));
      expect(total(), tracks.length + 2);
      expect(queue.getQueue().nextUp.length, 1, reason: '"play next" lands in Next Up');

      await queue.addToNextUp(PlayableSlice.simple([tracks.first, tracks.first], source));
      expect(queue.getQueue().nextUp.length, 3);
      expect(total(), tracks.length + 4);

      await queue.clearNextUp();
      expect(queue.getQueue().nextUp, isEmpty);
      expect(total(), tracks.length + 1, reason: 'only the track added to the end is left');
    }, timeout: slow);

    testApp('items can be reordered and removed', (tester) async {
      await prep(tester);
      await fresh(tester);
      final before = names(queue.getQueue().queue);

      await queue.reorderByOffset(1, 3);
      final moved = names(queue.getQueue().queue);
      expect(moved.length, before.length);
      expect(moved, isNot(before), reason: 'two different tracks swapped places');
      expect(moved.toSet(), before.toSet());

      await queue.removeAtOffset(1);
      expect(total(), tracks.length - 1);
      await queue.removeQueueItem(queue.getQueue().queue.first);
      expect(total(), tracks.length - 2);
    }, timeout: slow);

    testApp('shuffle keeps the same tracks, and turning it off restores the order', (tester) async {
      await prep(tester);
      await fresh(tester);
      List<String?> all() {
        final q = queue.getQueue();
        return [...names(q.previousTracks), q.currentTrack!.baseItem!.name, ...names(q.nextUp), ...names(q.queue)]
          ..sort((a, b) => '$a'.compareTo('$b'));
      }

      final before = all();
      await queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
      expect(queue.playbackOrder, FinampPlaybackOrder.shuffled);
      expect(all(), before);

      await queue.togglePlaybackOrder();
      expect(queue.playbackOrder, FinampPlaybackOrder.linear);
      expect(all(), before);
    }, timeout: slow);

    testApp('repeat cycles through three different modes', (tester) async {
      await prep(tester);
      queue.loopMode = FinampLoopMode.none;
      queue.toggleLoopMode();
      final first = queue.loopMode;
      queue.toggleLoopMode();
      final second = queue.loopMode;
      queue.toggleLoopMode();
      expect({first, second, queue.loopMode}.length, 3);
      queue.loopMode = FinampLoopMode.none;
      expect(queue.loopMode, FinampLoopMode.none);
    });

    testApp('playback speed is remembered', (tester) async {
      await prep(tester);
      queue.playbackSpeed = 1.5;
      expect(queue.playbackSpeed, 1.5);
      queue.playbackSpeed = 1.0;
    });

    testApp('skipping forwards and back moves through the queue', (tester) async {
      await prep(tester);
      await fresh(tester);
      final first = queue.getQueue().currentTrack!;

      await queue.skipByOffset(1);
      await tester.waitUntil(
        () => queue.getQueue().currentTrack?.id != first.id && queue.getQueue().previousTracks.length == 1,
        seconds: 15,
        what: 'the next track becoming current',
      );
      await queue.skipByOffset(-1);
      await tester.waitUntil(
        () => queue.getQueue().currentTrack?.id == first.id,
        seconds: 15,
        what: 'the first track coming back',
      );
    }, timeout: slow);

    testApp('clearing the queue stops playback', (tester) async {
      await prep(tester);
      await queue.stopAndClearQueue();
      await tester.settle();

      final info = queue.getQueue();
      expect(info.currentTrack, isNull);
      expect(info.queue, isEmpty);
      expect(GetIt.instance<MusicPlayerBackgroundTask>().playbackState.value.playing, isFalse);
    }, timeout: slow);
  });
}
