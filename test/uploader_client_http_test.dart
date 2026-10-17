import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:crypto/crypto.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/test_env.dart';

class _FakeConnectivity extends ConnectivityPlatform with MockPlatformInterfaceMixin {
  _FakeConnectivity(this.result);
  List<ConnectivityResult> result;
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => result;
}

http.Response _json(int status, Object body, {Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...?headers});

void main() {
  late TestEnv env;
  late List<http.BaseRequest> seen;
  late Future<http.Response> Function(http.Request request) respond;
  late UploaderClient client;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    env.updateSettings((s) {
      s.uploaderUrl = 'http://192.168.1.10:8688';
      s.uploaderToken = 'secret-token';
      s.uploaderEnabled = true;
      s.uploaderNetworkPolicy = 'local';
    });
    seen = [];
    respond = (_) async => _json(200, {});
    client = UploaderClient(
      httpClient: MockClient((request) async {
        seen.add(request);
        return respond(request);
      }),
    );
  });

  tearDown(() => env.dispose());

  group('capabilities: why the uploader can or cannot be used', () {
    test('reachable, with what it can do', () async {
      respond = (_) async => _json(200, {
        'ytdlp': true,
        'ytdlpVersion': '2026.08.19',
        'ytdlpJsRuntime': 'node',
        'ytdlpTagging': true,
        'pairing': true,
      });

      final caps = await client.capabilities();

      expect(caps.state, UploaderState.ok);
      expect(caps.reachable, isTrue);
      expect(caps.ytdlp, isTrue);
      expect(caps.ytdlpVersion, '2026.08.19');
      expect(caps.jsRuntime, 'node');
      expect(caps.tagging, isTrue);
      expect(caps.pairing, isTrue);
      expect(seen.single.headers['Authorization'], 'Bearer secret-token');
      expect(seen.single.url.path, '/api/v1/capabilities');
    });

    test('an empty JS runtime means "none found"', () async {
      respond = (_) async => _json(200, {'ytdlp': true, 'ytdlpJsRuntime': ''});

      expect((await client.capabilities()).jsRuntime, isNull);
    });

    test('no address configured', () async {
      env.updateSettings((s) => s.uploaderUrl = '');

      final caps = await client.capabilities();

      expect(caps.state, UploaderState.unconfigured);
      expect(seen, isEmpty, reason: 'nothing to contact');
    });

    test('an address the security rules forbid is reported without any request', () async {
      env.updateSettings((s) {
        s.uploaderUrl = 'http://music.example.com';
        s.uploaderNetworkPolicy = 'internet';
      });

      final caps = await client.capabilities();

      expect(caps.state, UploaderState.unconfigured);
      expect(caps.problem, contains('https'));
      expect(seen, isEmpty);
    });

    test('wrong token', () async {
      respond = (_) async =>
          _json(401, {'error': 'invalid or missing token', 'code': 'unauthorized', 'component': 'auth'});

      final caps = await client.capabilities();

      expect(caps.state, UploaderState.unauthorized);
      expect(caps.problem, contains('token'));
    });

    test('something that is not an uploader (plain 404)', () async {
      respond = (_) async => http.Response('<html>nginx</html>', 404);

      expect((await client.capabilities()).state, UploaderState.notAnUploader);
    });

    test('a reply the app cannot read', () async {
      respond = (_) async => http.Response('[1,2,3]', 200);

      expect((await client.capabilities()).state, UploaderState.notAnUploader);
    });

    test('unreachable server', () async {
      respond = (_) async => throw const SocketException('Connection refused');

      final caps = await client.capabilities();

      expect(caps.state, UploaderState.unreachable);
      expect(caps.problem, contains('refused'));
    });

    test('a reverse proxy answering 502 means the uploader behind it is down', () async {
      respond = (_) async => http.Response('<h1>Bad Gateway</h1>', 502);

      final caps = await client.capabilities();

      expect(caps.state, UploaderState.unreachable);
      expect(caps.problem, contains('reverse proxy'));
    });

    test('a slow server times out with a plain sentence', () async {
      client = UploaderClient(
        httpClient: MockClient((request) async {
          await Future<void>.delayed(const Duration(seconds: 11));
          return _json(200, {});
        }),
      );

      final caps = await client.capabilities();

      expect(caps.state, UploaderState.unreachable);
      expect(caps.problem, contains('too long'));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('errors keep both the friendly text and the technical truth', () {
    test('a server error reaches the caller with code, component, detail and request id', () async {
      respond = (_) async => _json(
        422,
        {
          'error': 'YouTube says this video isn\'t available.',
          'code': 'video_unavailable',
          'component': 'ytdlp',
          'detail': 'ERROR: [youtube] x: Video unavailable',
        },
        headers: {'x-request-id': 'ab12cd34'},
      );

      Object? error;
      try {
        await client.ytSearch('x');
      } catch (e) {
        error = e;
      }

      final e = error as UploaderException;
      expect(e.message, contains("isn't available"));
      expect(e.code, 'video_unavailable');
      expect(e.source, ErrorSource.ytdlp);
      expect(e.requestId, 'ab12cd34');
      expect(e.technical, contains('Video unavailable'));
      expect(e.message, isNot(contains('ERROR:')));
    });

    test('the "YouTube is off on this server" case reads as instructions', () async {
      respond = (_) async => _json(501, {'error': 'x', 'code': 'ytdlp_disabled', 'component': 'ytdlp'});

      final e = await _catch(() => client.ytTrending());

      expect(e.message, contains('DIAPASON_YTDLP_ENABLED'));
    });

    test('401 tells the user what to do about it', () async {
      respond = (_) async =>
          _json(401, {'error': 'invalid or missing token', 'code': 'unauthorized', 'component': 'auth'});

      final e = await _catch(() => client.ytSearch('x'));

      expect(e.message, contains('token'));
      expect(e.message, contains('Pair again'));
    });

    test('a connection failure is labelled as a connection problem, not an uploader one', () async {
      respond = (_) async => throw const HandshakeException('bad certificate');

      final e = await _catch(() => client.ytSearch('x'));

      expect(e.source, ErrorSource.connection);
      expect(e.message, contains('certificate'));
    });
  });

  group('yt-dlp proxy requests', () {
    test('search sends the query, the limit and the token', () async {
      respond = (_) async => _json(200, {
        'results': [
          {'id': 'dQw4w9WgXcQ', 'title': 'Song', 'artist': 'Artist', 'durationSecs': 212},
        ],
      });

      final results = await client.ytSearch('daft punk & friends', limit: 7);

      expect(results.single.title, 'Song');
      expect(results.single.durationSecs, 212);
      final url = seen.single.url;
      expect(url.path, '/api/v1/ytdlp/search');
      expect(url.queryParameters, {'q': 'daft punk & friends', 'limit': '7'});
      expect(seen.single.headers['Authorization'], 'Bearer secret-token');
    });

    test('stream and thumbnail addresses are built from the configured server', () {
      expect(client.ytStream('dQw4w9WgXcQ').toString(), 'http://192.168.1.10:8688/api/v1/ytdlp/stream/dQw4w9WgXcQ');
      expect(client.ytThumbnail('dQw4w9WgXcQ').path, '/api/v1/ytdlp/thumb/dQw4w9WgXcQ');
    });

    test('a trailing slash on the saved address does not double up', () {
      env.updateSettings((s) => s.uploaderUrl = 'http://192.168.1.10:8688///');

      expect(client.ytStream('dQw4w9WgXcQ').path, '/api/v1/ytdlp/stream/dQw4w9WgXcQ');
    });
  });

  group('server-side download', () {
    test('queues the job, polls until done, and reports a new file', () async {
      var polls = 0;
      respond = (req) async {
        if (req.method == 'POST') {
          expect(jsonDecode(req.body), containsPair('id', 'dQw4w9WgXcQ'));
          return _json(202, {'id': 'job1', 'state': 'queued'});
        }
        polls++;
        return _json(200, {'id': 'job1', 'state': polls < 3 ? 'running' : 'done', 'path': 'A/B/C.m4a'});
      };

      final result = await client.ytDownloadToLibrary(
        'dQw4w9WgXcQ',
        artist: 'A',
        title: 'C',
        pollInterval: const Duration(milliseconds: 5),
      );

      expect(result.ok, isTrue);
      expect(result.duplicate, isFalse);
      expect(polls, 3);
      final body = jsonDecode((seen.first as http.Request).body) as Map;
      expect(body, containsPair('artist', 'A'));
      expect(body, containsPair('title', 'C'));
    });

    test('a track that was already there is reported as a duplicate, not a failure', () async {
      respond = (req) async =>
          req.method == 'POST' ? _json(202, {'id': 'j'}) : _json(200, {'state': 'done', 'duplicate': true});

      final result = await client.ytDownloadToLibrary('dQw4w9WgXcQ', pollInterval: const Duration(milliseconds: 1));

      expect(result.ok, isTrue);
      expect(result.duplicate, isTrue);
    });

    test('a failed job surfaces the server\'s explanation and blames yt-dlp', () async {
      respond = (req) async => req.method == 'POST'
          ? _json(202, {'id': 'j'})
          : _json(200, {
              'state': 'error',
              'error': 'YouTube is asking this server to prove it isn\'t a bot.',
              'code': 'youtube_blocked',
              'detail': 'Sign in to confirm',
            });

      final result = await client.ytDownloadToLibrary('dQw4w9WgXcQ', pollInterval: const Duration(milliseconds: 1));

      expect(result.ok, isFalse);
      expect(result.message, contains('bot'));
      expect(result.source, ErrorSource.ytdlp);
    });

    test('refused up front (server busy, YouTube off) is a failure with the server\'s words', () async {
      respond = (_) async => _json(501, {'error': 'x', 'code': 'ytdlp_disabled', 'component': 'ytdlp'});

      final result = await client.ytDownloadToLibrary('dQw4w9WgXcQ');

      expect(result.ok, isFalse);
      expect(result.message, contains('turned off'));
    });

    test('gives up with a hint if the job never finishes', () async {
      respond = (req) async => req.method == 'POST' ? _json(202, {'id': 'j'}) : _json(200, {'state': 'running'});

      final result = await client.ytDownloadToLibrary(
        'dQw4w9WgXcQ',
        timeout: const Duration(milliseconds: 50),
        pollInterval: const Duration(milliseconds: 10),
      );

      expect(result.ok, isFalse);
      expect(result.message, contains('still working'));
    });
  });

  group('uploading a file', () {
    late File file;

    setUp(() async {
      file = File('${env.dir.path}/Artist - Song.mp3')..writeAsBytesSync(List.generate(2048, (i) => i % 251));
    });

    String hashOfFile() => sha256.convert(file.readAsBytesSync()).toString();

    test('asks whether the server already has the file, then sends metadata before the audio', () async {
      respond = (req) async {
        if (req.url.path.endsWith('/exists')) return _json(200, {'exists': false});
        return _json(201, {'path': 'Artist/Song.mp3', 'hash': hashOfFile(), 'duplicate': false});
      };

      final result = await client.uploadFile(
        file,
        artist: 'Artist',
        title: 'Song',
        album: 'LP',
        trackNumber: 3,
        year: 1999,
      );

      expect(result.ok, isTrue);
      expect(result.duplicate, isFalse);
      expect(seen.first.url.queryParameters['hash'], hashOfFile());
      final upload = seen.last as http.Request;
      expect(upload.method, 'POST');
      expect(upload.headers['Authorization'], 'Bearer secret-token');
      expect(upload.headers['content-type'], startsWith('multipart/form-data'));
      final body = latin1.decode(upload.bodyBytes);
      final metaAt = body.indexOf('name="metadata"');
      final fileAt = body.indexOf('name="file"');
      expect(metaAt, greaterThan(-1));
      expect(fileAt, greaterThan(metaAt), reason: 'the server requires metadata before the audio');
      final json = body.substring(body.indexOf('{', metaAt), body.indexOf('}', metaAt) + 1);
      final meta = jsonDecode(json) as Map;
      expect(meta, containsPair('artist', 'Artist'));
      expect(meta, containsPair('album', 'LP'));
      expect(meta, containsPair('trackNumber', 3));
      expect(meta, containsPair('ext', 'mp3'));
      expect(upload.bodyBytes.length, greaterThan(file.lengthSync()), reason: 'the whole file went out');
    });

    test('an identical file already on the server is not sent again', () async {
      respond = (_) async => _json(200, {'exists': true, 'path': 'x'});

      final result = await client.uploadFile(file);

      expect(result.ok, isTrue);
      expect(result.duplicate, isTrue);
      expect(seen, hasLength(1), reason: 'only the exists check');
    });

    test('409 means a duplicate, which is fine', () async {
      respond = (req) async =>
          req.url.path.endsWith('/exists') ? _json(200, {'exists': false}) : _json(409, {'duplicate': true});

      expect((await client.uploadFile(file)).duplicate, isTrue);
    });

    for (final (status, serverSays, fragment) in [
      (401, 'invalid or missing token', 'token'),
      (413, 'That file is larger than this server accepts.', 'larger'),
      (415, 'unsupported audio format', 'audio format'),
    ]) {
      test('HTTP $status is explained', () async {
        respond = (req) async => req.url.path.endsWith('/exists')
            ? _json(200, {'exists': false})
            : _json(status, {'error': serverSays, 'code': 'c', 'component': 'uploader'});

        final result = await client.uploadFile(file);

        expect(result.ok, isFalse);
        expect(result.message, contains(fragment));
      });
    }

    test('a storage failure on the server is blamed on the uploader, with its explanation', () async {
      respond = (req) async => req.url.path.endsWith('/exists')
          ? _json(200, {'exists': false})
          : _json(500, {
              'error': "The server couldn't save the file — check free space.",
              'code': 'storage_failed',
              'component': 'uploader',
            });

      final result = await client.uploadFile(file);

      expect(result.ok, isFalse);
      expect(result.source, ErrorSource.uploader);
      expect(result.message, contains('free space'));
    });

    test('a file type the server would refuse is stopped locally', () async {
      final bad = File('${env.dir.path}/notes.html')..writeAsStringSync('<html>');

      final result = await client.uploadFile(bad);

      expect(result.ok, isFalse);
      expect(result.message, contains('.html'));
      expect(seen, isEmpty);
    });

    test('a file that vanished is reported as a device problem', () async {
      final result = await client.uploadFile(File('${env.dir.path}/gone.mp3'));

      expect(result.ok, isFalse);
      expect(result.source, ErrorSource.device);
    });

    test('with no usable address nothing is attempted', () async {
      env.updateSettings((s) => s.uploaderUrl = '');

      final result = await client.uploadFile(file);

      expect(result.ok, isFalse);
      expect(seen, isEmpty);
    });
  });

  group('pairing', () {
    test('returns the token the server issued', () async {
      respond = (req) async {
        expect(req.url.path, '/api/v1/pair');
        expect(req.headers.containsKey('Authorization'), isFalse, reason: 'pairing is how you get a token');
        expect(jsonDecode(req.body), containsPair('name', 'My Mac'));
        return _json(201, {'token': 'fresh-device-token', 'deviceId': 'd1', 'name': 'My Mac'});
      };

      expect(await client.pair('http://192.168.1.10:8688/', 'My Mac'), 'fresh-device-token');
    });

    test('a closed pairing window comes back as the server\'s own explanation', () async {
      respond = (_) async => _json(403, {
        'error': 'pairing is closed — open it from an already-paired device',
        'code': 'forbidden',
        'component': 'uploader',
      });

      final e = await _catch(() => client.pair('http://192.168.1.10:8688', 'x'));

      expect(e.message, contains('pairing is closed'));
    });

    test('an address that breaks the https rule is refused before any request', () async {
      final e = await _catch(() => client.pair('http://music.example.com', 'x'));

      expect(e.code, 'blocked_address');
      expect(seen, isEmpty);
    });
  });

  group('"only on Wi-Fi" for automatic transfers', () {
    final original = ConnectivityPlatform.instance;
    tearDown(() => ConnectivityPlatform.instance = original);

    test('mobile data blocks them when the setting is on', () async {
      env.updateSettings((s) => s.uploaderWifiOnly = true);
      ConnectivityPlatform.instance = _FakeConnectivity([ConnectivityResult.mobile]);

      expect(await client.automaticTransferAllowed(), isFalse);
    });

    test('Wi-Fi, Ethernet and VPN allow them', () async {
      env.updateSettings((s) => s.uploaderWifiOnly = true);
      for (final type in [ConnectivityResult.wifi, ConnectivityResult.ethernet, ConnectivityResult.vpn]) {
        ConnectivityPlatform.instance = _FakeConnectivity([type]);
        expect(await client.automaticTransferAllowed(), isTrue, reason: '$type');
      }
    });

    test('the setting off means mobile data is fine', () async {
      env.updateSettings((s) => s.uploaderWifiOnly = false);
      ConnectivityPlatform.instance = _FakeConnectivity([ConnectivityResult.mobile]);

      expect(await client.automaticTransferAllowed(), isTrue);
    });
  });
}

Future<UploaderException> _catch(Future<Object?> Function() action) async {
  try {
    await action();
  } on UploaderException catch (e) {
    return e;
  }
  fail('expected an UploaderException');
}
