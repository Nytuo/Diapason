import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One request the mock server received.
class SeenRequest {
  SeenRequest(this.endpoint, this.params, this.at);

  final String endpoint;
  final Map<String, String> params;
  final DateTime at;

  String? get client => params['c'];
  @override
  String toString() => '$endpoint $params';
}

/// A tiny, deterministic Subsonic/Navidrome server held in memory.
///
/// Used two ways: as an [http.Client] for unit tests ([client]), and as a real
/// HTTP server on loopback ([start]) so the whole app can be driven against it
/// in an integration test with no internet and no real music server.
///
/// It checks credentials like the real thing (token = md5(password + salt)),
/// answers failures the way Subsonic does (HTTP 200 with `status: failed`), and
/// records every request so tests can assert what the app told the server.
class MockSubsonicServer {
  MockSubsonicServer({this.username = 'tester', this.password = 'hunter2', this.audio});

  final String username;
  final String password;

  /// Bytes served for `stream`/`download`. Defaults to a short silent MP3-ish blob.
  final List<int>? audio;

  final requests = <SeenRequest>[];

  /// Synced lyrics by song id; songs not listed here have none.
  final Map<String, List<String>> lyrics = {
    's2': ['Closing time', 'Every new beginning', 'Comes from some other', "Beginning's end"],
  };
  final starred = <String>{};
  final playlists = <String, ({String name, List<String> songs})>{
    'pl1': (name: 'Road trip', songs: ['s1', 's3']),
  };

  /// Make every API call fail with this Subsonic error code (e.g. 70, 40), for error-path tests.
  int? failWith;

  /// Delay before answering, to test timeouts and loading states.
  Duration latency = Duration.zero;

  HttpServer? _server;

  // ---- the library --------------------------------------------------------

  static const artists = <Map<String, dynamic>>[
    {'id': 'ar1', 'name': 'Alpha Artist', 'albumCount': 1, 'coverArt': 'co1'},
    {'id': 'ar2', 'name': 'Beta Band', 'albumCount': 1, 'coverArt': 'co2'},
  ];

  static const albums = <Map<String, dynamic>>[
    {
      'id': 'al1',
      'name': 'First Album',
      'artist': 'Alpha Artist',
      'artistId': 'ar1',
      'songCount': 2,
      'year': 2001,
      'duration': 60,
      'coverArt': 'co1',
    },
    {
      'id': 'al2',
      'name': 'Second Album',
      'artist': 'Beta Band',
      'artistId': 'ar2',
      'songCount': 1,
      'year': 2010,
      'duration': 30,
      'coverArt': 'co2',
    },
  ];

  static const songs = <Map<String, dynamic>>[
    {
      'id': 's1',
      'title': 'Opening',
      'album': 'First Album',
      'albumId': 'al1',
      'artist': 'Alpha Artist',
      'artistId': 'ar1',
      'track': 1,
      'year': 2001,
      'duration': 30,
      'suffix': 'mp3',
      'contentType': 'audio/mpeg',
      'size': 1000,
      'bitRate': 128,
      'coverArt': 'co1',
    },
    {
      'id': 's2',
      'title': 'Closing',
      'album': 'First Album',
      'albumId': 'al1',
      'artist': 'Alpha Artist',
      'artistId': 'ar1',
      'track': 2,
      'year': 2001,
      'duration': 30,
      'suffix': 'mp3',
      'contentType': 'audio/mpeg',
      'size': 1000,
      'bitRate': 128,
      'coverArt': 'co1',
    },
    {
      'id': 's3',
      'title': 'Beta Song',
      'album': 'Second Album',
      'albumId': 'al2',
      'artist': 'Beta Band',
      'artistId': 'ar2',
      'track': 1,
      'year': 2010,
      'duration': 30,
      'suffix': 'mp3',
      'contentType': 'audio/mpeg',
      'size': 1000,
      'bitRate': 128,
      'coverArt': 'co2',
    },
  ];

  Map<String, dynamic> _song(Map<String, dynamic> s) => {
    ...s,
    if (starred.contains(s['id'])) 'starred': '2026-01-01T00:00:00Z',
  };

  // ---- request recording helpers -----------------------------------------

  Iterable<SeenRequest> calls(String endpoint) => requests.where((r) => r.endpoint == endpoint);

  /// The now-playing / play-count reports the app sent, in order.
  List<SeenRequest> get scrobbles => calls('scrobble').toList();

  // ---- serving ------------------------------------------------------------

  /// An http client that answers from memory.
  http.Client get client => MockClient((request) async {
    final reply = await handle(request.url);
    return http.Response.bytes(reply.body, reply.status, headers: reply.headers);
  });

  /// Starts a real server on 127.0.0.1 and returns its base address.
  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      final reply = await handle(request.uri, rangeHeader: request.headers.value('range'));
      request.response.statusCode = reply.status;
      reply.headers.forEach(request.response.headers.set);
      request.response.add(reply.body);
      await request.response.close();
    });
    return Uri.parse('http://127.0.0.1:${_server!.port}');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<({int status, List<int> body, Map<String, String> headers})> handle(Uri url, {String? rangeHeader}) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final endpoint = url.pathSegments.isEmpty ? '' : url.pathSegments.last.replaceAll('.view', '');
    final p = url.queryParameters;
    requests.add(SeenRequest(endpoint, p, DateTime.now()));

    ({int status, List<int> body, Map<String, String> headers}) json(
      Map<String, dynamic> inner, {
      String status = 'ok',
    }) => (
      status: 200,
      body: utf8.encode(
        jsonEncode({
          'subsonic-response': {'status': status, 'version': '1.16.1', 'type': 'mock', ...inner},
        }),
      ),
      headers: {'content-type': 'application/json'},
    );
    ({int status, List<int> body, Map<String, String> headers}) error(int code, String message) => json({
      'error': {'code': code, 'message': message},
    }, status: 'failed');

    // Credentials, exactly as a real server checks them.
    final expected = md5.convert(utf8.encode('$password${p['s'] ?? ''}')).toString();
    if (p['u'] != username || p['t'] != expected) return error(40, 'Wrong username or password');
    if (failWith != null && endpoint != 'ping') return error(failWith!, 'forced failure');

    switch (endpoint) {
      case 'ping':
        return failWith != null ? error(failWith!, 'forced failure') : json({});
      case 'getArtists':
        return json({
          'artists': {
            'index': [
              {
                'name': 'A',
                'artist': [artists[0]],
              },
              {
                'name': 'B',
                'artist': [artists[1]],
              },
            ],
          },
        });
      case 'getArtist':
        final a = artists.firstWhere((a) => a['id'] == p['id'], orElse: () => {});
        if (a.isEmpty) return error(70, 'Artist not found');
        return json({
          'artist': {...a, 'album': albums.where((x) => x['artistId'] == a['id']).toList()},
        });
      case 'getAlbum':
        final a = albums.firstWhere((a) => a['id'] == p['id'], orElse: () => {});
        if (a.isEmpty) return error(70, 'Album not found');
        return json({
          'album': {...a, 'song': songs.where((s) => s['albumId'] == a['id']).map(_song).toList()},
        });
      case 'getSong':
        final s = songs.firstWhere((s) => s['id'] == p['id'], orElse: () => {});
        return s.isEmpty ? error(70, 'Song not found') : json({'song': _song(s)});
      case 'getAlbumList2':
        final offset = int.tryParse(p['offset'] ?? '') ?? 0;
        final size = int.tryParse(p['size'] ?? '') ?? 500;
        return json({
          'albumList2': {'album': albums.skip(offset).take(size).toList()},
        });
      case 'search3':
        final q = (p['query'] ?? '').toLowerCase();
        bool hit(Map<String, dynamic> m, List<String> keys) =>
            q.isEmpty || keys.any((k) => '${m[k] ?? ''}'.toLowerCase().contains(q));
        return json({
          'searchResult3': {
            'artist': artists.where((a) => hit(a, ['name'])).toList(),
            'album': albums.where((a) => hit(a, ['name', 'artist'])).toList(),
            'song': songs.where((s) => hit(s, ['title', 'album', 'artist'])).map(_song).toList(),
          },
        });
      case 'getRandomSongs':
        return json({
          'randomSongs': {'song': songs.map(_song).toList()},
        });
      case 'getSimilarSongs2':
        return json({
          'similarSongs2': {'song': songs.where((s) => s['id'] != p['id']).map(_song).toList()},
        });
      case 'getSongsByGenre':
        return json({
          'songsByGenre': {'song': songs.map(_song).toList()},
        });
      case 'getGenres':
        return json({
          'genres': {
            'genre': [
              {'value': 'Rock', 'albumCount': 2, 'songCount': 3},
            ],
          },
        });
      case 'getStarred2':
        return json({
          'starred2': {
            'song': songs.where((s) => starred.contains(s['id'])).map(_song).toList(),
            'album': [],
            'artist': [],
          },
        });
      case 'star':
        starred.addAll(url.queryParametersAll['id'] ?? const []);
        return json({});
      case 'unstar':
        starred.removeAll(url.queryParametersAll['id'] ?? const []);
        return json({});
      case 'getPlaylists':
        return json({
          'playlists': {
            'playlist': [
              for (final e in playlists.entries) {'id': e.key, 'name': e.value.name, 'songCount': e.value.songs.length},
            ],
          },
        });
      case 'getPlaylist':
        final pl = playlists[p['id']];
        if (pl == null) return error(70, 'Playlist not found');
        return json({
          'playlist': {
            'id': p['id'],
            'name': pl.name,
            'entry': [for (final id in pl.songs) songs.firstWhere((s) => s['id'] == id)],
          },
        });
      case 'createPlaylist':
        final id = 'pl${playlists.length + 1}';
        playlists[id] = (name: p['name'] ?? 'New', songs: [...?url.queryParametersAll['songId']]);
        return json({
          'playlist': {'id': id, 'name': p['name']},
        });
      case 'updatePlaylist':
        final pl = playlists[p['playlistId']];
        if (pl == null) return error(70, 'Playlist not found');
        playlists[p['playlistId']!] = (
          name: p['name'] ?? pl.name,
          songs: [...pl.songs, ...?url.queryParametersAll['songIdToAdd']],
        );
        return json({});
      case 'getInternetRadioStations':
        return json({'internetRadioStations': {}});
      case 'getLyricsBySongId':
        final lines = lyrics[p['id']];
        if (lines == null) return error(70, 'No lyrics');
        return json({
          'lyricsList': {
            'structuredLyrics': [
              {
                'synced': true,
                'line': [
                  for (var i = 0; i < lines.length; i++) {'start': i * 4000, 'value': lines[i]},
                ],
              },
            ],
          },
        });
      case 'getLyrics':
        return error(70, 'No lyrics');
      case 'scrobble':
        return json({});
      case 'stream':
      case 'download':
        final data = audio ?? _silence;
        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final parts = rangeHeader.substring(6).split('-');
          final start = int.tryParse(parts[0]) ?? 0;
          final end = parts.length > 1 && parts[1].isNotEmpty ? int.parse(parts[1]) : data.length - 1;
          return (
            status: 206,
            body: data.sublist(start, (end + 1).clamp(0, data.length)),
            headers: {
              'content-type': 'audio/mpeg',
              'content-range': 'bytes $start-$end/${data.length}',
              'accept-ranges': 'bytes',
            },
          );
        }
        return (status: 200, body: data, headers: {'content-type': 'audio/mpeg', 'accept-ranges': 'bytes'});
      case 'getCoverArt':
        return (status: 200, body: _png, headers: {'content-type': 'image/png'});
    }
    return error(0, 'Unknown endpoint $endpoint');
  }

  /// A real, playable, silent MP3 (the project's fixture) when available.
  static List<int> get _silence {
    final f = File('test/fixtures/music/test.mp3');
    return f.existsSync() ? f.readAsBytesSync() : List.filled(1024, 0);
  }

  static final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );
}
