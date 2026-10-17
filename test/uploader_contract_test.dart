import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/fake_ytdlp.dart';
import 'support/test_env.dart';
import 'support/uploader_process.dart';

void main() {
  late final String? unavailable;
  late TestEnv env;
  late String binary;
  UploaderProcess? server;
  FakeYtDlp? fake;

  setUpAll(() async {
    unavailable = await UploaderProcess.unavailableReason() ?? (FakeYtDlp.supported ? null : 'needs a POSIX shell');
    if (unavailable != null) return;
    final scratch = await Directory.systemTemp.createTemp('uploader_build_');
    binary = await UploaderProcess.build(scratch);
  });

  setUp(() async {
    if (unavailable != null) return;
    env = await TestEnv.create();
    await env.openHive();
  });

  tearDown(() async {
    await server?.stop();
    server = null;
    if (unavailable == null) await env.dispose();
  });

  Future<UploaderClient> connect({bool ytdlp = true, String? token, Map<String, String> extraEnv = const {}}) async {
    fake = await FakeYtDlp.create(env.dir);
    server = await UploaderProcess.start(
      binary,
      env.dir,
      env: {
        if (ytdlp) ...{
          'DIAPASON_YTDLP_ENABLED': 'true',
          'DIAPASON_YTDLP_BIN': fake!.path,
          'DIAPASON_YTDLP_AUTO_UPDATE': 'false',
        },
        ...extraEnv,
      },
    );
    env.updateSettings((s) {
      s.uploaderUrl = server!.baseUrl.toString();
      s.uploaderToken = token ?? server!.token;
      s.uploaderEnabled = true;
    });
    return UploaderClient();
  }

  void contract(String name, Future<void> Function() body) {
    test(name, () async {
      if (unavailable != null) markTestSkipped(unavailable!);
      if (unavailable != null) return;
      await body();
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  File audioFile(String name, [String content = 'pretend audio bytes']) {
    final f = File(p.join(env.dir.path, name));
    f.writeAsStringSync(content);
    return f;
  }

  List<File> libraryFiles() => server!.musicDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => !p.basename(f.path).startsWith('.') && !f.path.contains('.diapason-uploader'))
      .toList();

  group('connecting', () {
    contract('the app understands what the server says it can do', () async {
      final client = await connect();

      final caps = await client.capabilities();

      expect(caps.state, UploaderState.ok);
      expect(caps.ytdlp, isTrue);
      expect(caps.ytdlpVersion, '2099.01.01');
      expect(caps.pairing, isTrue);
    });

    contract('a server with YouTube off says so, in words that tell you what to change', () async {
      final client = await connect(ytdlp: false);

      expect((await client.capabilities()).ytdlp, isFalse);
      Object? error;
      try {
        await client.ytSearch('x');
      } catch (e) {
        error = e;
      }
      expect(error, isA<UploaderException>().having((e) => e.code, 'code', 'ytdlp_disabled'));
      expect(FriendlyError.message(error), contains('DIAPASON_YTDLP_ENABLED'));
    });

    contract('a wrong token is recognised as such, and endless guessing is throttled', () async {
      final client = await connect(token: 'definitely-not-the-token-0000000000');

      expect((await client.capabilities()).state, UploaderState.unauthorized);

      for (var i = 0; i < 10; i++) {
        await client.capabilities();
      }
      final limited = await server!.raw('GET', '/api/v1/capabilities', authToken: 'still-wrong-wrong-wrong-wrong');
      expect(limited.status, 429);
      expect(limited.headers['retry-after'], isNotNull);
    });

    contract('every error has the same shape and a request id for bug reports', () async {
      await connect();

      final bad = await server!.raw('GET', '/api/v1/exists?hash=nothex');
      final body = jsonDecode(bad.body) as Map;

      expect(bad.status, 400);
      expect(body.keys, containsAll(['error', 'code', 'component']));
      expect(body['code'], 'bad_request');
      expect(bad.headers['x-request-id'], matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    contract('responses carry the hardening headers', () async {
      await connect();

      final r = await server!.raw('GET', '/healthz');

      expect(r.headers['x-content-type-options'], 'nosniff');
      expect(r.headers['cache-control'], 'no-store');
    });
  });

  group('uploading music', () {
    contract('a file is stored under Artist/Album and a second copy is recognised as a duplicate', () async {
      final client = await connect();
      final file = audioFile('Artist - Song.mp3');

      final first = await client.uploadFile(
        file,
        artist: 'The Artist',
        album: 'The Album',
        title: 'The Song',
        trackNumber: 2,
      );
      final second = await client.uploadFile(
        file,
        artist: 'The Artist',
        album: 'The Album',
        title: 'The Song',
        trackNumber: 2,
      );

      expect(first.ok, isTrue);
      expect(first.duplicate, isFalse);
      expect(second.ok, isTrue);
      expect(second.duplicate, isTrue);
      final stored = libraryFiles();
      expect(stored, hasLength(1));
      expect(stored.single.path, endsWith(p.join('The Artist', 'The Album', '02 - The Song.mp3')));
      expect(stored.single.readAsStringSync(), 'pretend audio bytes');
    });

    contract('a duplicate never touches what is already in the library', () async {
      final client = await connect();
      final file = audioFile('a.mp3', 'same content');
      await client.uploadFile(file, artist: 'A', album: 'B', title: 'C');
      final stored = libraryFiles().single;
      final before = stored.statSync();
      final tree = server!.musicDir.listSync(recursive: true).map((e) => e.path).toSet();

      final again = await client.uploadFile(file, artist: 'Other', album: 'Elsewhere', title: 'Copy');

      expect(again.duplicate, isTrue);
      expect(stored.statSync().modified, before.modified);
      expect(stored.readAsStringSync(), 'same content');
      final after = server!.musicDir.listSync(recursive: true).map((e) => e.path).toSet();
      expect(after.difference(tree), isEmpty, reason: 'no new file or folder appeared');
    });

    contract('a different file with the same tags gets its own name instead of replacing the first', () async {
      final client = await connect();
      await client.uploadFile(audioFile('1.mp3', 'one'), artist: 'A', album: 'B', title: 'C');
      await client.uploadFile(audioFile('2.mp3', 'two'), artist: 'A', album: 'B', title: 'C');

      final contents = libraryFiles().map((f) => f.readAsStringSync()).toSet();
      expect(contents, {'one', 'two'});
    });

    contract('the server\'s "exists" check agrees with the app\'s hash', () async {
      final client = await connect();
      final file = audioFile('x.mp3', 'hash me');
      final hash = sha256.convert(file.readAsBytesSync()).toString();

      expect(await client.exists(hash), isFalse);
      await client.uploadFile(file, artist: 'A', title: 'T');
      expect(await client.exists(hash), isTrue);
    });

    contract('non-audio uploads and path tricks are refused by the server itself', () async {
      await connect();
      final boundary = 'b0und4ry';
      Future<int> post(String meta, String data) async {
        final client = HttpClient();
        final req = await client.postUrl(server!.baseUrl.resolve('/api/v1/upload'));
        req.headers.set('Authorization', 'Bearer ${server!.token}');
        req.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
        req.write(
          '--$boundary\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n$meta\r\n'
          '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="x"\r\n\r\n$data\r\n--$boundary--\r\n',
        );
        final res = await req.close();
        await res.drain<void>();
        client.close();
        return res.statusCode;
      }

      expect(await post('{"artist":"A","title":"T","ext":"html"}', '<script>'), 415);
      expect(await post('{"artist":"..","album":"..","title":"x","ext":"../../etc/passwd"}', 'x'), 415);
      final outside = Directory(p.join(server!.musicDir.parent.path, 'etc'));
      expect(outside.existsSync(), isFalse, reason: 'nothing escaped the library folder');
    });
  });

  group('pairing', () {
    contract('a device gets its own token, which works until it is revoked', () async {
      final client = await connect();

      final token = await client.pair(server!.baseUrl.toString(), 'Test Mac');
      expect(token, isNot(server!.token));

      env.updateSettings((s) => s.uploaderToken = token);
      expect((await client.capabilities()).state, UploaderState.ok);

      final devices = jsonDecode((await server!.raw('GET', '/api/v1/devices')).body) as Map;
      final id = (devices['devices'] as List).single['id'] as String;
      expect((await server!.raw('DELETE', '/api/v1/devices/$id')).status, 204);

      expect((await client.capabilities()).state, UploaderState.unauthorized);
    });

    contract('a request relayed by a proxy cannot pair, even from a private address', () async {
      await connect();

      final r = await server!.raw(
        'POST',
        '/api/v1/pair',
        headers: {'X-Forwarded-For': '203.0.113.9'},
        body: {'name': 'x'},
        authToken: '',
      );

      expect(r.status, 403);
      expect(jsonDecode(r.body)['error'], contains('local network'));
    });

    contract('pairing turned off is reported clearly', () async {
      final client = await connect(extraEnv: {'DIAPASON_PAIRING': 'off'});

      Object? error;
      try {
        await client.pair(server!.baseUrl.toString(), 'x');
      } catch (e) {
        error = e;
      }

      expect(FriendlyError.message(error), contains('disabled'));
    });
  });

  group('YouTube through the uploader', () {
    contract('search, trending and related come back as tracks', () async {
      final client = await connect();

      final found = await client.ytSearch('rick', limit: 5);
      expect(found.map((e) => e.id), [
        'dQw4w9WgXcQ',
        '9bZkp7q19f0',
      ], reason: 'channels and bad ids are dropped server-side');
      expect(found.first.artist, 'Rick Astley');
      expect(found.first.durationSecs, 212);

      expect((await client.ytTrending(limit: 2)), isNotEmpty);
      expect((await client.ytRelated('jNQXAC9IVRw')).map((e) => e.id), isNot(contains('jNQXAC9IVRw')));
    });

    contract('a pasted link resolves to that one video', () async {
      final client = await connect();

      final found = await client.ytSearch('https://youtu.be/jNQXAC9IVRw');

      expect(found.single.title, 'Me at the zoo');
    });

    contract('downloading puts a tagged file straight into the library, once', () async {
      final client = await connect();

      final first = await client.ytDownloadToLibrary('dQw4w9WgXcQ', pollInterval: const Duration(milliseconds: 100));
      final second = await client.ytDownloadToLibrary('dQw4w9WgXcQ', pollInterval: const Duration(milliseconds: 100));

      expect(first.ok, isTrue);
      expect(first.duplicate, isFalse);
      expect(second.duplicate, isTrue);
      final stored = libraryFiles().single;
      expect(stored.path, contains(p.join('Rick Astley', 'Whenever You Need Somebody')));
      expect(stored.readAsStringSync(), contains('dQw4w9WgXcQ'));
      expect(
        Directory(
          p.join(env.dir.path, 'work'),
        ).listSync().whereType<Directory>().where((d) => p.basename(d.path).startsWith('dl-')),
        isEmpty,
        reason: 'temporary download folders are cleaned up',
      );
    });

    contract('the server will not be pointed at anything but YouTube', () async {
      await connect();

      for (final target in [
        'http://169.254.169.254/latest/meta-data',
        'file:///etc/passwd',
        'https://evil.example/watch?v=dQw4w9WgXcQ',
        '--exec=touch /tmp/pwned',
      ]) {
        final r = await server!.raw('POST', '/api/v1/ytdlp/download', body: {'url': target});
        expect(r.status, 400, reason: target);
        expect(jsonDecode(r.body)['code'], 'bad_target');
      }
      expect(fake!.operations, isEmpty, reason: 'yt-dlp was never even started');
    });

    contract('YouTube saying no is relayed with the right blame and a readable sentence', () async {
      final client = await connect();
      await fake!.setMode('bot');

      Object? error;
      try {
        await client.ytSearch('x');
      } catch (e) {
        error = e;
      }
      final e = error as UploaderException;
      expect(e.code, 'youtube_blocked');
      expect(e.source, ErrorSource.ytdlp);
      expect(e.message, contains('bot'));
      expect(e.message, isNot(contains('ERROR:')));
      expect(e.detail, contains('Sign in to confirm'), reason: 'the technical line is kept for the log');
      expect(e.requestId, isNotNull);

      final job = await client.ytDownloadToLibrary('dQw4w9WgXcQ', pollInterval: const Duration(milliseconds: 100));
      expect(job.ok, isFalse);
      expect(job.source, ErrorSource.ytdlp);
      expect(job.message, contains('bot'));
      expect(libraryFiles(), isEmpty);
    });

    contract('an unavailable video and a network failure are told apart', () async {
      final client = await connect();

      await fake!.setMode('unavailable');
      final unavailable = await _failure(() => client.ytSearch('x'));
      expect(unavailable.code, 'video_unavailable');

      await fake!.setMode('network');
      final network = await _failure(() => client.ytSearch('x'));
      expect(network.code, 'server_network');
      expect(network.message, contains('reach YouTube'));
    });
  });
}

Future<UploaderException> _failure(Future<Object?> Function() action) async {
  try {
    await action();
  } on UploaderException catch (e) {
    return e;
  }
  fail('expected an UploaderException');
}
