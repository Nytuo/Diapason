import 'dart:io';

import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mock_uploader.dart';
import 'support/test_env.dart';

/// The app's uploader client talking to the mock over a real socket: proves the mock speaks the protocol the
/// app expects, so integration tests built on it mean something.
void main() {
  late TestEnv env;
  late MockUploader server;
  late UploaderClient client;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    server = MockUploader();
    final url = await server.start();
    env.updateSettings((s) {
      s.uploaderUrl = url.toString();
      s.uploaderToken = server.token;
      s.uploaderEnabled = true;
      s.uploaderNetworkPolicy = 'local';
    });
    client = UploaderClient();
  });

  tearDown(() async {
    await server.stop();
    await env.dispose();
  });

  test('capabilities report YouTube, runtime and pairing', () async {
    final caps = await client.capabilities();
    expect(caps.state, UploaderState.ok);
    expect(caps.ytdlp, isTrue);
    expect(caps.jsRuntime, 'deno');
    expect(caps.pairing, isTrue);
  });

  test('a wrong token is unauthorized; YouTube off is reported', () async {
    env.updateSettings((s) => s.uploaderToken = 'nope');
    expect((await client.capabilities()).state, UploaderState.unauthorized);
    env.updateSettings((s) => s.uploaderToken = server.token);
    server.ytdlp = false;
    expect((await client.capabilities()).ytdlp, isFalse);
  });

  test('upload sends metadata and the file once; the same file again is a duplicate', () async {
    final dir = await Directory.systemTemp.createTemp('mock_up');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.mp3')..writeAsBytesSync(List.generate(500, (i) => i % 200 + 32));

    final first = await client.uploadFile(file, artist: 'A', album: 'B', title: 'C', trackNumber: 3);
    expect(first.ok, isTrue);
    expect(server.uploads.single['artist'], 'A');
    expect(server.uploads.single['trackNumber'], 3);

    final again = await client.uploadFile(file, artist: 'A', album: 'B', title: 'C');
    expect(again.duplicate, isTrue);
    expect(server.uploads.length, 1);
  });

  test('pairing needs the window open, then hands out a token that works', () async {
    await expectLater(client.pair(server.baseUrl.toString(), 'Test phone'), throwsA(isA<UploaderException>()));
    await client.openPairing();
    expect(await client.pair(server.baseUrl.toString(), 'Test phone'), 'device-token-1');
    env.updateSettings((s) => s.uploaderToken = 'device-token-1');
    expect((await client.capabilities()).state, UploaderState.ok);
  });

  test('YouTube proxy: search, trending, related, and server-side download polling', () async {
    expect((await client.ytSearch('abc')).first.title, 'Result for abc');
    expect((await client.ytTrending()).single.title, 'Trending One');
    expect((await client.ytRelated('x')).single.title, 'Related');

    final done = await client.ytDownloadToLibrary(
      'aaaaaaaaaaa',
      artist: 'Mock',
      pollInterval: const Duration(milliseconds: 20),
    );
    expect(done.ok, isTrue);
    expect(server.downloads.single['id'], 'aaaaaaaaaaa');

    server.jobError = 'YouTube wants proof you are human.';
    final failed = await client.ytDownloadToLibrary('bbbbbbbbbbb', pollInterval: const Duration(milliseconds: 20));
    expect(failed.ok, isFalse);
    expect(failed.message, contains('human'));
  });
}
