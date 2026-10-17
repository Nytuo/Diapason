import 'dart:convert';
import 'dart:io';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/plex_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// A loopback Plex: answers `/path` with `{"MediaContainer": ...}` and records every request.
class _FakePlex {
  late HttpServer server;
  final Map<String, Object> routes = {};
  final List<Uri> requests = [];
  int status = 200;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req.uri);
      req.response.statusCode = status;
      final body = routes[req.uri.path];
      req.response.write(jsonEncode(body == null ? {} : {'MediaContainer': body}));
      await req.response.close();
    });
  }

  String get address => 'http://127.0.0.1:${server.port}';
  Future<void> stop() => server.close(force: true);
}

Map<String, dynamic> _track(int id, {String title = 'Opening'}) => {
  'ratingKey': '$id',
  'title': title,
  'parentTitle': 'First',
  'parentKey': '/library/metadata/20',
  'grandparentTitle': 'Artist',
  'grandparentKey': '/library/metadata/10',
  'index': id,
  'parentIndex': 1,
  'year': 2020,
  'duration': 61000,
  'thumb': '/t',
  'type': 'track',
  'Media': [
    {
      'Part': [
        {'key': '/library/parts/$id/file.flac'},
      ],
    },
  ],
};

void main() {
  late _FakePlex plex;
  late PlexBackend backend;

  setUp(() async {
    plex = _FakePlex();
    await plex.start();
    plex.routes['/library/sections'] = {
      'Directory': [
        {'type': 'movie', 'key': '1'},
        {'type': 'artist', 'key': '5'},
      ],
    };
    plex.routes['/library/sections/5/albums'] = {
      'Metadata': [
        {
          'ratingKey': '20',
          'title': 'First',
          'parentTitle': 'Artist',
          'parentKey': '/library/metadata/10',
          'year': 2020,
          'leafCount': 3,
          'thumb': '/a',
        },
        {'ratingKey': '21'},
      ],
    };
    plex.routes['/library/sections/5/all'] = {
      'Metadata': [
        {'ratingKey': '10', 'title': 'Artist', 'thumb': '/x'},
        {'ratingKey': '11'},
      ],
    };
    plex.routes['/library/metadata/20/children'] = {
      'Metadata': [_track(1), _track(2, title: 'Closing')],
    };
    plex.routes['/library/metadata/10/children'] = {
      'Metadata': [
        {'ratingKey': '20', 'title': 'First'},
      ],
    };
    plex.routes['/playlists'] = {
      'Metadata': [
        {'ratingKey': '30', 'title': 'Mix', 'playlistType': 'audio', 'leafCount': 4, 'composite': '/c'},
        {'ratingKey': '31', 'title': 'Film list', 'playlistType': 'video'},
      ],
    };
    plex.routes['/playlists/30/items'] = {
      'Metadata': [_track(1)],
    };
    plex.routes['/library/all'] = {
      'Metadata': [_track(1, title: 'Found')],
    };
    plex.routes['/library/metadata/1'] = {
      'Metadata': [_track(1)],
    };
    plex.routes['/library/metadata/20'] = {
      'Metadata': [
        {'ratingKey': '20', 'title': 'First', 'type': 'album'},
      ],
    };
    plex.routes['/library/metadata/10'] = {
      'Metadata': [
        {'ratingKey': '10', 'title': 'Artist', 'type': 'artist'},
      ],
    };
    backend = PlexBackend(
      MediaSourceConfig(
        sourceId: 'plex1',
        kind: MediaSourceKind.plex,
        name: 'Plex',
        publicAddress: plex.address,
        accessToken: 'tok',
      ),
    );
  });

  tearDown(() async {
    await backend.logout();
    await plex.stop();
  });

  test('ping finds the music section and the token rides on every request', () async {
    expect(backend.isConnected, isFalse);
    expect(await backend.ping(), isTrue);
    expect(backend.isConnected, isTrue);
    expect(plex.requests.single.queryParameters['X-Plex-Token'], 'tok');
    expect(backend.sourceId, 'plex1');
    expect(backend.capabilities.transcoding, isTrue);
    expect(backend.capabilities.playlists, isFalse);
  });

  test('no music library, a server error, or an unreachable server mean "not connected"', () async {
    plex.routes['/library/sections'] = {'Directory': []};
    expect(await backend.ping(), isFalse);
    plex.status = 500;
    expect(await backend.ping(), isFalse);
    final dead = PlexBackend(
      MediaSourceConfig(sourceId: 'p', kind: MediaSourceKind.plex, name: 'x', publicAddress: 'http://127.0.0.1:1'),
    );
    addTearDown(dead.logout);
    expect(await dead.ping(), isFalse);
    expect(await dead.getItems(), isEmpty);
  });

  test('albums, artists and playlists are mapped; blanks get friendly names', () async {
    final albums = await backend.getItems(includeItemTypes: 'MusicAlbum');
    expect(albums.map((a) => a.name), containsAll(['First', 'Unknown Album']));
    expect(albums.firstWhere((a) => a.name == 'First').albumArtist, 'Artist');

    final artists = await backend.getItems(includeItemTypes: 'MusicArtist');
    expect(artists.map((a) => a.name), containsAll(['Artist', 'Unknown Artist']));

    final playlists = await backend.getItems(includeItemTypes: 'Playlist');
    expect(playlists.map((p) => p.name), ['Mix'], reason: 'video playlists are not music');
  });

  test('sorting asks Plex for the matching order', () async {
    await backend.getItems(sortBy: 'DateCreated');
    await backend.getItems(sortBy: 'PlayCount');
    final sorts = plex.requests.where((u) => u.path.endsWith('/albums')).map((u) => u.queryParameters['sort']);
    expect(sorts, ['addedAt:desc', 'viewCount:desc']);
  });

  test('children: album → tracks, artist → albums, playlist → tracks', () async {
    final album = (await backend.getItems(includeItemTypes: 'MusicAlbum')).firstWhere((a) => a.name == 'First');
    final tracks = await backend.getItems(parentItem: album);
    expect(tracks.map((t) => t.name), ['Opening', 'Closing']);
    expect(tracks.first.runTimeTicks, 61000 * 10000);

    final artist = (await backend.getItems(includeItemTypes: 'MusicArtist')).first;
    expect((await backend.getItems(parentItem: artist)).single.name, 'First');

    final playlist = (await backend.getItems(includeItemTypes: 'Playlist')).single;
    expect((await backend.getItems(parentItem: playlist)).single.name, 'Opening');
  });

  test('searching returns tracks', () async {
    final found = await backend.getItems(searchTerm: 'op');
    expect(found.single.name, 'Found');
    expect(plex.requests.last.queryParameters['query'], 'op');
  });

  test('getItemById picks the right kind', () async {
    expect((await backend.getItemById(BaseItemId('plex1~1')))!.name, 'Opening');
    expect((await backend.getItemById(BaseItemId('plex1~20')))!.type, 'MusicAlbum');
    expect((await backend.getItemById(BaseItemId('plex1~10')))!.type, 'MusicArtist');
    expect(await backend.getItemById(BaseItemId('plex1~404')), isNull);
  });

  test('streaming uses the media part, authenticated; a track without media explains itself', () async {
    final track = (await backend.getItems(parentItem: (await backend.getItems()).first)).first;
    final source = await backend.resolveStream(track, transcode: false);
    expect(source.uri.path, '/library/parts/1/file.flac');
    expect(source.uri.queryParameters['X-Plex-Token'], 'tok');

    final bare = (await backend.getItemById(BaseItemId('plex1~20')))!;
    await expectLater(backend.resolveStream(bare, transcode: false), throwsStateError);
  });

  test('downloads: original adds download=1; transcoding drives the universal transcoder', () async {
    final track = (await backend.getItems(parentItem: (await backend.getItems()).first)).first;

    final original = await backend.resolveDownload(track);
    expect(original.uri.queryParameters['download'], '1');
    final orig2 = await backend.resolveDownload(
      track,
      transcodingProfile: DownloadProfile(transcodeCodec: FinampTranscodingCodec.original),
    );
    expect(orig2.uri.path, original.uri.path);

    final lossy = await backend.resolveDownload(
      track,
      transcodingProfile: DownloadProfile(transcodeCodec: FinampTranscodingCodec.mp3, bitrate: 192000),
    );
    expect(lossy.uri.path, '/music/:/transcode/universal/start.mp3');
    expect(lossy.uri.queryParameters['musicBitrate'], '192');
    expect(lossy.uri.queryParameters['path'], '/library/metadata/1');
    expect(lossy.uri.queryParameters['X-Plex-Client-Identifier'], 'plex1');

    final lossless = await backend.resolveDownload(
      track,
      transcodingProfile: DownloadProfile(transcodeCodec: FinampTranscodingCodec.flac),
    );
    expect(lossless.uri.queryParameters.containsKey('musicBitrate'), isFalse);
  });

  test('images need an image id and are authenticated through the URL', () async {
    final track = (await backend.getItems(parentItem: (await backend.getItems()).first)).first;
    expect(backend.imageUrl(track)!.path, '/library/metadata/1/thumb');
    final plain = (await backend.getItems(includeItemTypes: 'MusicArtist')).last;
    expect(backend.imageUrl(plain), isNull);
    expect(backend.imageHeaders, isEmpty);
  });

  test('playback is reported to the timeline in the right state', () async {
    final track = (await backend.getItems(parentItem: (await backend.getItems()).first)).first;
    plex.requests.clear();
    await backend.reportPlaybackStart(track);
    await backend.reportPlaybackProgress(track, position: const Duration(seconds: 5), isPaused: true);
    await backend.reportPlaybackProgress(track, position: const Duration(seconds: 6), isPaused: false);
    await backend.reportPlaybackStopped(track, position: const Duration(seconds: 7));
    final states = plex.requests.map((u) => u.queryParameters['state']);
    expect(states, ['playing', 'paused', 'playing', 'stopped']);
    expect(plex.requests[1].queryParameters['time'], '5000');
    expect(plex.requests[1].queryParameters['duration'], '61000');
  });

  test('what Plex does not offer here is inert or unsupported', () async {
    final track = (await backend.getItemById(BaseItemId('plex1~1')))!;
    expect(await backend.getRadioStations(), isEmpty);
    expect(await backend.getInstantMix(track), isEmpty);
    expect(await backend.getLyrics(track), isNull);
    await backend.setFavorite(track, isFavorite: true);
    expect(() => backend.createPlaylist('x'), throwsUnsupportedError);
    expect(() => backend.addToPlaylist(track, []), throwsUnsupportedError);
    expect(() => backend.removeFromPlaylist(track, []), throwsUnsupportedError);
    expect(() => backend.updatePlaylistMetadata(track), throwsUnsupportedError);
    expect(() => backend.reorderPlaylist(track, []), throwsUnsupportedError);
  });
}
