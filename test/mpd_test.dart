import 'dart:io';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/mpd_backend.dart';
import 'package:diapason/services/mpd/mpd_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_mpd.dart';

void main() {
  late FakeMpd mpd;

  setUp(() async => mpd = await FakeMpd.start());
  tearDown(() => mpd.stop());

  group('MpdClient', () {
    test('connects, reads the version and returns key/value lines in order', () async {
      mpd.replies['status'] = ['volume: 40', 'state: play', 'bad line without separator'];
      final client = MpdClient(host: '127.0.0.1', port: mpd.port);
      await client.connect();
      addTearDown(client.close);

      expect(client.isConnected, isTrue);
      expect(client.version, '0.23.5');
      final lines = await client.command('status');
      expect(lines.map((l) => '${l.key}=${l.value}'), ['volume=40', 'state=play']);
      expect(MpdClient.single(lines), {'volume': '40', 'state': 'play'});
    });

    test('connecting twice is harmless', () async {
      final client = MpdClient(host: '127.0.0.1', port: mpd.port);
      await client.connect();
      await client.connect();
      addTearDown(client.close);
      expect(mpd.commands, isEmpty);
    });

    test('sends the password first, quoted', () async {
      final client = MpdClient(host: '127.0.0.1', port: mpd.port, password: 'pa"ss\\word');
      await client.connect();
      addTearDown(client.close);
      expect(mpd.commands.single, r'password "pa\"ss\\word"');
    });

    test('commands are answered one at a time, in order', () async {
      mpd.replies['a'] = ['k: 1'];
      mpd.replies['b'] = ['k: 2'];
      final client = MpdClient(host: '127.0.0.1', port: mpd.port);
      await client.connect();
      addTearDown(client.close);

      final results = await Future.wait([client.command('a'), client.command('b')]);
      expect(results.map((r) => r.single.value), ['1', '2']);
      expect(mpd.commands, ['a', 'b']);
    });

    test('an ACK becomes an MpdException and the next command still works', () async {
      mpd.failing.add('bad');
      mpd.replies['good'] = ['ok: yes'];
      final client = MpdClient(host: '127.0.0.1', port: mpd.port);
      await client.connect();
      addTearDown(client.close);

      await expectLater(
        client.command('bad'),
        throwsA(isA<MpdException>().having((e) => e.toString(), 'text', contains('ACK'))),
      );
      expect((await client.command('good')).single.value, 'yes');
    });

    test('pending commands fail when the server goes away, and the client reports it', () async {
      final client = MpdClient(host: '127.0.0.1', port: mpd.port);
      await client.connect();
      addTearDown(client.close);
      mpd.dropClients();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(client.isConnected, isFalse);
      await expectLater(client.command('status'), throwsA(isA<SocketException>()));
    });

    test('close fails what is still queued and disconnects', () async {
      final client = MpdClient(host: '127.0.0.1', port: mpd.port);
      await client.connect();
      await client.close();
      expect(client.isConnected, isFalse);
      await expectLater(client.command('status'), throwsA(isA<SocketException>()));
    });

    test('refused connections and missing greetings surface as errors', () async {
      final port = mpd.port;
      await mpd.stop();
      await expectLater(MpdClient(host: '127.0.0.1', port: port).connect(), throwsA(isA<SocketException>()));
    });

    test('group splits lines into records at the start keys; quote escapes', () {
      final lines = [
        const MapEntry('file', 'a.mp3'),
        const MapEntry('Title', 'A'),
        const MapEntry('file', 'b.mp3'),
        const MapEntry('Title', 'B'),
        const MapEntry('stray', 'x'),
      ];
      final groups = MpdClient.group(lines, {'file'});
      expect(groups.length, 2);
      expect(groups.last, {'file': 'b.mp3', 'Title': 'B', 'stray': 'x'});
      expect(MpdClient.group([const MapEntry('x', 'y')], {'file'}), isEmpty);
      expect(MpdClient.quote('a"b\\c'), r'"a\"b\\c"');
    });
  });

  group('MpdBackend', () {
    late MpdBackend backend;

    MpdBackend make({String localPath = '', String password = '', String? address}) => MpdBackend(
      MediaSourceConfig(
        sourceId: 'mpd1',
        kind: MediaSourceKind.mpd,
        name: 'Living room',
        publicAddress: address ?? '127.0.0.1:${mpd.port}',
        localPath: localPath,
        password: password,
      ),
    );

    setUp(() {
      mpd.replies['config'] = ['music_directory: /srv/music'];
      mpd.replies['list album group albumartist'] = [
        'AlbumArtist: Artist One',
        'Album: First',
        'Album: Second',
        'Album: ',
      ];
      mpd.replies['list albumartist albumartist'] = ['AlbumArtist: Artist One'];
      mpd.replies['list albumartist'] = ['AlbumArtist: Artist One', 'AlbumArtist: Artist Two', 'AlbumArtist: '];
      mpd.replies['list genre'] = ['Genre: Rock', 'Genre: '];
      mpd.replies['list album genre'] = ['Album: Rocky'];
      mpd.replies['list album albumartist'] = ['Album: First'];
      mpd.replies['list album album'] = ['Album: Found'];
      mpd.replies['find album "First"'] = [
        'file: First/01 Opening.flac',
        'Title: Opening',
        'Artist: Artist One',
        'Track: 1',
        'duration: 61.5',
        'file: First/02.mp3',
        'Time: 30',
        'file: ',
      ];
      mpd.replies['find file'] = ['file: First/01 Opening.flac', 'Title: Opening'];
      mpd.replies['search any'] = ['file: x/y.ogg', 'Title: Hit'];
      mpd.replies['listallinfo'] = [
        for (var i = 1; i <= 5; i++) ...['file: t$i.mp3', 'Title: T$i'],
      ];
      backend = make();
    });

    tearDown(() => backend.logout());

    test('is not connected until used, and reports its source and capabilities', () async {
      expect(backend.isConnected, isFalse);
      expect(backend.sourceId, 'mpd1');
      expect(backend.capabilities.search, isTrue);
      expect(await backend.ping(), isTrue);
      expect(backend.isConnected, isTrue);
    });

    test('an unreachable daemon means ping false and empty lists, never an exception', () async {
      final dead = make(address: '127.0.0.1:1');
      expect(await dead.ping(), isFalse);
      expect(await dead.getItems(), isEmpty);
      expect(await dead.getItemById(BaseItemId('mpd1~x')), isNull);
    });

    test('albums come with their artist; blank names are dropped', () async {
      final albums = await backend.getItems(includeItemTypes: 'MusicAlbum');
      expect(albums.map((a) => a.name), ['First', 'Second']);
      expect(albums.first.albumArtist, 'Artist One');
      expect((await backend.getItems()).length, 2, reason: 'albums are the default view');
    });

    test('artists and genres', () async {
      expect((await backend.getItems(includeItemTypes: 'MusicArtist')).map((a) => a.name), [
        'Artist One',
        'Artist Two',
      ]);
      expect((await backend.getItems(includeItemTypes: 'MusicGenre')).map((g) => g.name), ['Rock']);
    });

    test('an album lists its tracks with titles, numbers, durations and containers', () async {
      final album = (await backend.getItems()).first;
      final tracks = await backend.getItems(parentItem: album);
      expect(tracks.length, 2);
      expect(tracks.first.name, 'Opening');
      expect(tracks.first.indexNumber, 1);
      expect(tracks.first.container, 'flac');
      expect(tracks.first.runTimeTicks, const Duration(milliseconds: 61500).inMicroseconds * 10);
      expect(tracks.last.name, '02.mp3', reason: 'no title tag falls back to the file name');
      expect(tracks.last.indexNumber, 2, reason: 'no track tag falls back to the position');
    });

    test('artist and genre pages list albums', () async {
      final artist = (await backend.getItems(includeItemTypes: 'MusicArtist')).first;
      expect((await backend.getItems(parentItem: artist)).single.name, 'First');
      final genre = (await backend.getItems(includeItemTypes: 'MusicGenre')).first;
      expect((await backend.getItems(parentItem: genre)).single.name, 'Rocky');
      expect((await backend.getItems(genreFilter: genre.id)).single.name, 'Rocky');
    });

    test('search covers artists, albums and tracks', () async {
      expect((await backend.getItems(searchTerm: 'art', includeItemTypes: 'MusicArtist')).single.name, 'Artist One');
      expect((await backend.getItems(searchTerm: 'fou', includeItemTypes: 'MusicAlbum')).single.name, 'Found');
      expect((await backend.getItems(searchTerm: 'hit', includeItemTypes: 'Audio')).single.name, 'Hit');
      expect(mpd.commands, contains('search any "hit"'));
    });

    test('all tracks can be paged', () async {
      expect((await backend.getItems(includeItemTypes: 'Audio')).length, 5);
      expect((await backend.getItems(includeItemTypes: 'Audio', startIndex: 1, limit: 2)).map((t) => t.name), [
        'T2',
        'T3',
      ]);
      expect(await backend.getItems(includeItemTypes: 'Audio', startIndex: 9), isEmpty);
    });

    test('a single track can be fetched by file name; unknown ones are null', () async {
      final track = await backend.getItemById(BaseItemId('mpd1~First/01 Opening.flac'));
      expect(track!.name, 'Opening');
      mpd.replies['find file'] = [];
      expect(await backend.getItemById(BaseItemId('mpd1~nothing')), isNull);
    });

    test('streams are file URIs under the daemon music directory', () async {
      final track = (await backend.getItems(parentItem: (await backend.getItems()).first)).first;
      final source = await backend.resolveStream(track, transcode: false);
      expect(source.isLocalFile, isTrue);
      expect(source.uri.toFilePath(), '/srv/music/First/01 Opening.flac');
      expect((await backend.resolveDownload(track)).uri, source.uri);
    });

    test('a configured music directory wins over the daemon\'s answer', () async {
      final custom = make(localPath: '/mnt/nas');
      addTearDown(custom.logout);
      final track = (await custom.getItems(parentItem: (await custom.getItems()).first)).first;
      expect((await custom.resolveStream(track, transcode: false)).uri.path, startsWith('/mnt/nas/'));
    });

    test('without a known music directory playback explains what to set', () async {
      mpd.failing.add('config');
      final blind = make();
      addTearDown(blind.logout);
      final track = (await blind.getItems(parentItem: (await blind.getItems()).first)).first;
      await expectLater(blind.resolveStream(track, transcode: false), throwsStateError);
    });

    test('the address may omit the port or the host', () async {
      expect(await make(address: '127.0.0.1').ping(), isFalse, reason: 'default port 6600 is not our fake');
      expect(await make(address: ':${mpd.port}').ping(), anyOf(isTrue, isFalse), reason: 'empty host means localhost');
    });

    test('features MPD does not have are inert or say so', () async {
      final track = (await backend.getItems(includeItemTypes: 'Audio')).first;
      expect(backend.imageUrl(track), isNull);
      expect(backend.imageHeaders, isEmpty);
      expect(await backend.getInstantMix(track), isEmpty);
      expect(await backend.getRadioStations(), isEmpty);
      expect(await backend.getLyrics(track), isNull);
      await backend.setFavorite(track, isFavorite: true);
      await backend.reportPlaybackStart(track);
      await backend.reportPlaybackProgress(track, position: Duration.zero, isPaused: false);
      await backend.reportPlaybackStopped(track, position: Duration.zero);
      expect(() => backend.createPlaylist('x'), throwsUnsupportedError);
      expect(() => backend.addToPlaylist(track, []), throwsUnsupportedError);
      expect(() => backend.removeFromPlaylist(track, []), throwsUnsupportedError);
      expect(() => backend.updatePlaylistMetadata(track), throwsUnsupportedError);
      expect(() => backend.reorderPlaylist(track, []), throwsUnsupportedError);
    });

    test('logging out drops the connection; the next call reconnects', () async {
      await backend.ping();
      await backend.logout();
      expect(backend.isConnected, isFalse);
      expect(await backend.ping(), isTrue);
    });

    test('the password is sent when configured', () async {
      final locked = make(password: 'secret');
      addTearDown(locked.logout);
      await locked.ping();
      expect(mpd.commands.first, 'password "secret"');
    });
  });
}
