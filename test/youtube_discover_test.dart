import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/discovery/youtube_discover_service.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/stub_youtube.dart';

/// "Discover queues": start from one track and keep following YouTube's suggestions.
void main() {
  late StubYouTube youtube;
  late YouTubeDiscoverService discover;

  setUp(() {
    youtube = StubYouTube();
    // The service looks YouTube up by its base type.
    GetIt.instance.registerSingleton<YouTubeService>(youtube);
    discover = YouTubeDiscoverService();
  });

  tearDown(() => GetIt.instance.reset());

  test('follows the first not-yet-seen suggestion at every step', () async {
    // a -> b -> c -> d, and every track also suggests the ones before it.
    final next = {'aaaaaaaaaaa': 'bbbbbbbbbbb', 'bbbbbbbbbbb': 'ccccccccccc', 'ccccccccccc': 'ddddddddddd'};
    youtube.onRelated = (seed) async => [
      ytTrack('aaaaaaaaaaa', 'A'),
      ytTrack('bbbbbbbbbbb', 'B'),
      if (next[seed.id.nativeId] case final id?) ytTrack(id, 'next $id'),
    ];

    final queue = await discover.radioFromSeed(ytTrack('aaaaaaaaaaa', 'A'), length: 4);

    expect(queue.map((t) => t.id.nativeId), ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc', 'ddddddddddd']);
  });

  test('never repeats a track', () async {
    youtube.onRelated = (_) async => [ytTrack('aaaaaaaaaaa', 'A'), ytTrack('bbbbbbbbbbb', 'B')];

    final queue = await discover.radioFromSeed(ytTrack('aaaaaaaaaaa', 'A'), length: 10);

    expect(queue.map((t) => t.id.nativeId).toSet(), hasLength(queue.length));
  });

  test('stops quietly when YouTube runs out of suggestions', () async {
    youtube.onRelated = (_) async => const [];

    final queue = await discover.radioFromSeed(ytTrack('aaaaaaaaaaa', 'A'), length: 40);

    expect(queue.map((t) => t.name), ['A'], reason: 'just the seed');
    expect(youtube.relatedAsked, hasLength(1));
  });

  test('never grows past the requested length', () async {
    var n = 0;
    youtube.onRelated = (_) async => [ytTrack('${(n++).toString().padLeft(11, 'x')}', 'T$n')];

    final queue = await discover.radioFromSeed(ytTrack('seedseedsee', 'Seed'), length: 6);

    expect(queue, hasLength(6));
  });

  test('radioFromQuery seeds from the best search result', () async {
    youtube.onSearch = (_) async => [ytTrack('aaaaaaaaaaa', 'Top hit'), ytTrack('bbbbbbbbbbb', 'Second')];
    youtube.onRelated = (_) async => [ytTrack('ccccccccccc', 'Related')];

    final queue = await discover.radioFromQuery('some band', length: 2);

    expect(youtube.queries, ['some band']);
    expect(queue.map((t) => t.name), ['Top hit', 'Related']);
  });

  test('radioFromQuery with no results gives an empty queue', () async {
    youtube.onSearch = (_) async => const [];

    expect(await discover.radioFromQuery('nothing'), isEmpty);
  });

  group('radioFromPlaylistTail', () {
    BaseItemDto library(String title, String artist) =>
        ItemMapper('jf-1').track(nativeId: title, name: title, artist: artist, duration: const Duration(minutes: 3));

    test('seeds from the end of the playlist, matching a library track to YouTube by artist and title', () async {
      youtube.onSearch = (q) async => [ytTrack('matchmatchma', 'Match for $q')];
      youtube.onRelated = (_) async => const [];

      final queue = await discover.radioFromPlaylistTail([library('First', 'A'), library('Last', 'B')], length: 3);

      expect(youtube.queries, ['B Last']);
      expect(queue.single.name, 'Match for B Last');
    });

    test('goes back through the playlist until something matches', () async {
      youtube.onSearch = (q) async => q == 'A First' ? [ytTrack('matchmatchma', 'Found')] : const [];
      youtube.onRelated = (_) async => const [];

      final queue = await discover.radioFromPlaylistTail([library('First', 'A'), library('Last', 'B')], length: 3);

      expect(youtube.queries, ['B Last', 'A First']);
      expect(queue.single.name, 'Found');
    });

    test('a YouTube track in the playlist is used as it is, with no search', () async {
      youtube.onRelated = (_) async => const [];

      final queue = await discover.radioFromPlaylistTail([ytTrack('aaaaaaaaaaa', 'Already YT')], length: 3);

      expect(youtube.queries, isEmpty);
      expect(queue.single.name, 'Already YT');
    });

    test('nothing matches: an empty queue, not an error', () async {
      expect(await discover.radioFromPlaylistTail([library('X', 'Y')]), isEmpty);
    });
  });
}
