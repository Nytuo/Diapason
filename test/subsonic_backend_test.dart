import 'package:crypto/crypto.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/subsonic_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'support/mock_subsonic.dart';
import 'support/test_env.dart';

/// The Subsonic/Navidrome backend against an in-memory server that checks
/// credentials and records everything the app says to it.
void main() {
  late TestEnv env;
  late MockSubsonicServer server;
  late SubsonicBackend backend;

  MediaSourceConfig config({String password = 'hunter2'}) => MediaSourceConfig(
    sourceId: 'sub-1',
    kind: MediaSourceKind.subsonic,
    name: 'Home Navidrome',
    publicAddress: 'http://music.test',
    username: 'tester',
    password: password,
  );

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    server = MockSubsonicServer();
    backend = SubsonicBackend(config(), client: server.client);
  });

  tearDown(() => env.dispose());

  group('connecting', () {
    test('ping succeeds with the right credentials', () async {
      expect(await backend.ping(), isTrue);
      expect(backend.isConnected, isTrue);
    });

    test('a wrong password is a failed ping, not an exception', () async {
      backend = SubsonicBackend(config(password: 'nope'), client: server.client);

      expect(await backend.ping(), isFalse);
      expect(backend.isConnected, isFalse);
    });

    test('the password never travels, only a salted token', () async {
      await backend.ping();

      final params = server.requests.single.params;
      expect(params['u'], 'tester');
      expect(params['s'], isNotEmpty);
      expect(params['t'], md5.convert(utf8.encode('hunter2${params['s']}')).toString());
      expect(params.values, isNot(contains('hunter2')));
      expect(params.containsKey('p'), isFalse);
    });

    test('identifies itself as "Diapason", which is what Navidrome shows as the player', () async {
      await backend.ping();

      expect(server.requests.single.client, 'Diapason');
    });
  });

  group('browsing', () {
    test('albums', () async {
      final albums = await backend.getItems(includeItemTypes: 'MusicAlbum');

      expect(albums.map((a) => a.name), containsAll(['First Album', 'Second Album']));
      expect(albums.first.id.sourceId, 'sub-1', reason: 'ids are scoped to this server');
    });

    test('artists', () async {
      final artists = await backend.getItems(includeItemTypes: 'MusicArtist');

      expect(artists.map((a) => a.name), ['Alpha Artist', 'Beta Band']);
    });

    test('an album\'s tracks, in order, with their details', () async {
      final album = (await backend.getItems(includeItemTypes: 'MusicAlbum')).firstWhere((a) => a.name == 'First Album');

      final tracks = await backend.getItems(parentItem: album, includeItemTypes: 'Audio');

      expect(tracks.map((t) => t.name), ['Opening', 'Closing']);
      expect(tracks.first.indexNumber, 1);
      expect(tracks.first.album, 'First Album');
      expect(tracks.first.runTimeTicksDuration(), const Duration(seconds: 30));
    });

    test('paging asks the server for the right window', () async {
      await backend.getItems(includeItemTypes: 'MusicAlbum', startIndex: 1, limit: 1);

      expect(server.calls('getAlbumList2').last.params, containsPair('offset', '1'));
      expect(server.calls('getAlbumList2').last.params, containsPair('size', '1'));
    });

    test('searching finds songs, albums and artists', () async {
      final results = await backend.getItems(searchTerm: 'beta');

      expect(results.map((r) => r.name), containsAll(['Beta Band', 'Second Album', 'Beta Song']));
      expect(results.map((r) => r.name), isNot(contains('Opening')));
    });

    test('favourites come from the server\'s starred list', () async {
      server.starred.add('s2');

      final favourites = await backend.getItems(filters: 'IsFavorite', includeItemTypes: 'Audio');

      expect(favourites.map((t) => t.name), ['Closing']);
      expect(favourites.single.userData?.isFavorite, isTrue);
    });

    test('playlists and their entries', () async {
      final lists = await backend.getItems(includeItemTypes: 'Playlist');
      final entries = await backend.getItems(parentItem: lists.single, includeItemTypes: 'Audio');

      expect(lists.single.name, 'Road trip');
      expect(entries.map((t) => t.name), ['Opening', 'Beta Song']);
    });

    final ids = ItemMapper('sub-1');

    test('looking an item up by id tries song, album, artist and playlist', () async {
      expect((await backend.getItemById(ids.id('s3')))?.name, 'Beta Song');
      expect((await backend.getItemById(ids.id('al2')))?.name, 'Second Album');
      expect((await backend.getItemById(ids.id('ar1')))?.name, 'Alpha Artist');
      expect((await backend.getItemById(ids.id('nothing'))), isNull);
    });

    test('a server error yields an empty list, not a crash', () async {
      server.failWith = 70;
      await backend.ping();

      expect(await backend.getItems(includeItemTypes: 'MusicAlbum'), isEmpty);
    });
  });

  group('playback addresses', () {
    test('a plain stream is the raw file with signed credentials', () async {
      final track = (await backend.getItems(searchTerm: 'Opening', includeItemTypes: 'Audio')).single;

      final source = await backend.resolveStream(track, transcode: false);

      expect(source.uri.path, endsWith('/rest/stream.view'));
      expect(source.uri.queryParameters, containsPair('id', 's1'));
      expect(source.uri.queryParameters, containsPair('format', 'raw'));
      expect(source.uri.queryParameters['t'], isNotEmpty);
    });

    test('cover art address carries the art id and size', () async {
      final track = (await backend.getItems(searchTerm: 'Opening', includeItemTypes: 'Audio')).single;

      final url = backend.imageUrl(track, maxWidth: 300);

      expect(url?.path, endsWith('/rest/getCoverArt.view'));
      expect(url?.queryParameters['size'], isNotNull);
    });
  });

  group('telling the server what is playing (Navidrome "Now Playing")', () {
    late BaseItemDto track;

    setUp(() async {
      track = (await backend.getItems(searchTerm: 'Opening', includeItemTypes: 'Audio')).single;
    });

    test('starting a track registers it as now playing, not as a play', () async {
      await backend.reportPlaybackStart(track);

      final scrobble = server.scrobbles.single;
      expect(scrobble.params, containsPair('id', 's1'));
      expect(scrobble.params, containsPair('submission', 'false'));
      expect(int.parse(scrobble.params['time']!), closeTo(DateTime.now().millisecondsSinceEpoch, 5000));
      expect(scrobble.client, 'Diapason');
    });

    test('progress updates refresh it, but not on every tick', () async {
      await backend.reportPlaybackStart(track);
      for (var i = 0; i < 5; i++) {
        await backend.reportPlaybackProgress(track, position: Duration(seconds: i), isPaused: false);
      }

      expect(server.scrobbles, hasLength(1), reason: 'the refresh interval has not elapsed');
    });

    test('a paused track is not announced again', () async {
      await backend.reportPlaybackProgress(track, position: Duration.zero, isPaused: true);

      expect(server.scrobbles, isEmpty);
    });

    test('stopping early does not count as a play', () async {
      await backend.reportPlaybackStart(track);
      await backend.reportPlaybackStopped(track, position: const Duration(seconds: 4));

      expect(server.scrobbles.where((s) => s.params['submission'] == 'true'), isEmpty);
    });

    test('listening to more than half counts as a play, timestamped when it began', () async {
      await backend.reportPlaybackStart(track);
      await backend.reportPlaybackStopped(track, position: const Duration(seconds: 20));

      final play = server.scrobbles.last;
      expect(play.params, containsPair('submission', 'true'));
      final startedMs = int.parse(play.params['time']!);
      expect(startedMs, closeTo(DateTime.now().subtract(const Duration(seconds: 20)).millisecondsSinceEpoch, 5000));
    });

    test('after a stop, the next track is announced straight away', () async {
      await backend.reportPlaybackStart(track);
      await backend.reportPlaybackStopped(track, position: const Duration(seconds: 1));
      await backend.reportPlaybackProgress(track, position: const Duration(seconds: 1), isPaused: false);

      expect(server.scrobbles.where((s) => s.params['submission'] == 'false'), hasLength(2));
    });
  });

  group('play counting rule', () {
    const song = Duration(minutes: 4);

    test('a skip is not a play', () {
      expect(SubsonicBackend.countsAsPlayed(const Duration(seconds: 8), song), isFalse);
      expect(SubsonicBackend.countsAsPlayed(const Duration(seconds: 119), song), isFalse);
    });

    test('half of the track counts', () {
      expect(SubsonicBackend.countsAsPlayed(const Duration(seconds: 120), song), isTrue);
    });

    test('long tracks need at most four minutes', () {
      const long = Duration(minutes: 40);
      expect(SubsonicBackend.countsAsPlayed(const Duration(minutes: 3), long), isFalse);
      expect(SubsonicBackend.countsAsPlayed(const Duration(minutes: 4), long), isTrue);
    });

    test('an unknown or very short length falls back to thirty seconds', () {
      expect(SubsonicBackend.countsAsPlayed(const Duration(seconds: 29), null), isFalse);
      expect(SubsonicBackend.countsAsPlayed(const Duration(seconds: 30), null), isTrue);
      expect(SubsonicBackend.countsAsPlayed(const Duration(seconds: 29), const Duration(seconds: 20)), isFalse);
    });
  });
}
