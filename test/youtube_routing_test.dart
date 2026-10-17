import 'dart:convert';
import 'dart:io';

import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_ytdlp.dart';
import 'support/test_env.dart';

http.Response _json(int status, Object body) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Where YouTube comes from — this computer's yt-dlp, the uploader's, or nowhere —
/// and what the app does with each answer. Real services, fake yt-dlp, fake server.
void main() {
  if (!FakeYtDlp.supported) {
    test('needs a POSIX shell', () {}, skip: 'fake yt-dlp is a shell script');
    return;
  }

  late TestEnv env;
  late FakeYtDlp fake;
  late LocalYtDlpService local;
  late UploaderClient uploader;
  late YouTubeAvailability availability;
  late YouTubeService youtube;
  late List<http.Request> uploaderRequests;
  late Future<http.Response> Function(http.Request) uploaderReply;

  Future<void> settle() async {
    await local.refresh();
    await availability.refresh();
  }

  void useUploader({bool want = true, bool ytdlp = true}) {
    env.updateSettings((s) {
      s.uploaderUrl = want ? 'http://192.168.1.10:8688' : '';
      s.uploaderToken = 'tok';
      s.uploaderYtProxy = want;
    });
    uploaderReply = (req) async {
      if (req.url.path.endsWith('/capabilities')) return _json(200, {'ytdlp': ytdlp, 'ytdlpVersion': '2026.08.19'});
      if (req.url.path.endsWith('/search')) {
        return _json(200, {
          'results': [
            {'id': 'aaaaaaaaaaa', 'title': 'From Server', 'artist': 'Server Artist', 'durationSecs': 100},
          ],
        });
      }
      if (req.url.path.endsWith('/trending')) {
        return _json(200, {
          'results': [
            {'id': 'bbbbbbbbbbb', 'title': 'Server Hit', 'artist': 'X', 'durationSecs': 90},
          ],
        });
      }
      return _json(200, {'results': []});
    };
  }

  void useLocal({bool installed = true}) {
    local.config.value = YtDlpConfig()..customBinaryPath = installed ? fake.path : '${env.dir.path}/missing';
  }

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    fake = await FakeYtDlp.create(env.dir);
    YtDlpPaths.searchDirsOverride = [];
    YtDlpPaths.execBlockedReason = null;
    uploaderRequests = [];
    uploaderReply = (_) async => _json(200, {});
    local = LocalYtDlpService();
    uploader = UploaderClient(
      httpClient: MockClient((req) async {
        uploaderRequests.add(req);
        return uploaderReply(req);
      }),
    );
    availability = YouTubeAvailability();
    GetIt.instance
      ..registerSingleton<LocalYtDlpService>(local)
      ..registerSingleton<UploaderClient>(uploader)
      ..registerSingleton<YouTubeAvailability>(availability);
    youtube = YouTubeService();
    GetIt.instance.registerSingleton<YouTubeService>(youtube);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    YtDlpPaths.searchDirsOverride = null;
    await env.dispose();
  });

  group('which route is used', () {
    test('this computer\'s yt-dlp when only it works', () async {
      useLocal();
      useUploader(want: false);
      await settle();

      expect(availability.source, YouTubeSource.local);
      expect(availability.status.value.available, isTrue);
    });

    test('the uploader when only it works', () async {
      useLocal(installed: false);
      useUploader();
      await settle();

      expect(availability.source, YouTubeSource.uploader);
    });

    test('this computer wins when both work, unless the user prefers the uploader', () async {
      useLocal();
      useUploader();
      await settle();
      expect(availability.source, YouTubeSource.local);

      local.config.value = YtDlpConfig()
        ..customBinaryPath = fake.path
        ..preferUploader = true;
      await availability.refresh();
      expect(availability.source, YouTubeSource.uploader);
    });

    test('an uploader that is down does not take the working local yt-dlp with it', () async {
      useLocal();
      useUploader();
      uploaderReply = (_) async => throw const SocketException('refused');
      await settle();

      expect(availability.source, YouTubeSource.local);
    });

    test('an uploader the user switched off for YouTube is ignored even if it could serve it', () async {
      useLocal(installed: false);
      useUploader();
      env.updateSettings((s) => s.uploaderYtProxy = false);
      await settle();

      expect(availability.source, YouTubeSource.none);
      expect(uploaderRequests, isEmpty, reason: 'and it is not even contacted');
    });

    test('nothing works: unavailable, and each reason is spelled out', () async {
      useLocal(installed: false);
      useUploader(ytdlp: false);
      await settle();

      final status = availability.status.value;
      expect(status.source, YouTubeSource.none);
      expect(status.available, isFalse);
      expect(status.problems.join(' '), contains('yt-dlp isn\'t set up on this computer'));
      expect(status.problems.join(' '), contains('DIAPASON_YTDLP_ENABLED'));
    });

    test('a rejected token is named as the problem', () async {
      useLocal(installed: false);
      useUploader();
      uploaderReply = (_) async => _json(401, {'error': 'invalid', 'code': 'unauthorized', 'component': 'auth'});
      await settle();

      expect(availability.status.value.problems.join(' '), contains('token'));
    });

    test('recovers by itself when the uploader comes back', () async {
      useLocal(installed: false);
      useUploader();
      uploaderReply = (_) async => throw const SocketException('refused');
      await settle();
      expect(availability.source, YouTubeSource.none);

      useUploader();
      await availability.refresh();
      expect(availability.source, YouTubeSource.uploader);
    });

    test('overlapping refreshes collapse instead of piling up', () async {
      useLocal(installed: false);
      useUploader();

      await Future.wait([for (var i = 0; i < 6; i++) availability.refresh()]);

      final probes = uploaderRequests.where((r) => r.url.path.endsWith('/capabilities')).length;
      expect(probes, lessThanOrEqualTo(2), reason: 'one in flight plus at most one follow-up');
    });
  });

  group('searching', () {
    test('through local yt-dlp, using the result count from settings', () async {
      useLocal();
      useUploader(want: false);
      env.updateSettings((s) => s.youtubeResultCount = 33);
      await settle();

      final results = await youtube.search('daft punk');

      expect(results.map((t) => t.name), ['Never Gonna Give You Up', 'Gangnam Style']);
      expect(results.first.id.sourceId, YouTubeService.sourceId);
      expect(results.first.id.nativeId, 'dQw4w9WgXcQ');
      expect(results.first.albumArtist, 'Rick Astley');
      expect(fake.operations.single.last, 'ytsearch33:daft punk');
    });

    test('through the uploader, passing the limit on', () async {
      useLocal(installed: false);
      useUploader();
      env.updateSettings((s) => s.youtubeResultCount = 12);
      await settle();

      final results = await youtube.search('anything');

      expect(results.single.name, 'From Server');
      final request = uploaderRequests.lastWhere((r) => r.url.path.endsWith('/search'));
      expect(request.url.queryParameters, {'q': 'anything', 'limit': '12'});
      expect(request.headers['Authorization'], 'Bearer tok');
    });

    test('the result count is kept within sane bounds', () async {
      useLocal();
      useUploader(want: false);
      env.updateSettings((s) => s.youtubeResultCount = 1000);
      await settle();

      await youtube.search('x');

      expect(fake.operations.single.last, 'ytsearch50:x');
    });

    test('a pasted link is looked up, not searched for', () async {
      useLocal();
      useUploader(want: false);
      await settle();

      final results = await youtube.search('https://youtu.be/jNQXAC9IVRw');

      expect(results.single.name, 'Me at the zoo');
      expect(fake.operations.single.where((a) => a.startsWith('ytsearch')), isEmpty);
    });

    test('an empty query does nothing', () async {
      useLocal();
      await settle();

      expect(await youtube.search('  '), isEmpty);
      expect(fake.operations, isEmpty);
    });

    test('failure is quiet by default and loud on request, in plain words', () async {
      useLocal();
      useUploader(want: false);
      await settle();
      await fake.setMode('bot');

      expect(await youtube.search('x'), isEmpty);
      final error = await _catch(() => youtube.search('x', throwOnError: true));
      expect(FriendlyError.message(error), contains('bot'));
      expect(FriendlyError.describe(error).source, ErrorSource.ytdlp);
    });

    test('with no route at all it says why instead of returning nothing silently', () async {
      useLocal(installed: false);
      useUploader(want: false);
      await settle();

      final error = await _catch(() => youtube.search('x', throwOnError: true));

      expect(error, isA<YouTubeUnavailable>());
      expect(FriendlyError.message(error), contains('YouTube isn\'t available'));
    });
  });

  group('rate limiting', () {
    test('YouTube pushing back pauses background lookups for a while', () async {
      useLocal();
      useUploader(want: false);
      await settle();
      expect(youtube.isRateLimited, isFalse);

      await fake.setMode('bot');
      await youtube.search('x');

      expect(youtube.isRateLimited, isTrue);
    });

    test('an unavailable video is not rate limiting', () async {
      useLocal();
      useUploader(want: false);
      await settle();
      await fake.setMode('unavailable');

      await youtube.search('x');

      expect(youtube.isRateLimited, isFalse);
    });
  });

  group('playing', () {
    test('locally: a direct https address and the container', () async {
      useLocal();
      useUploader(want: false);
      await settle();
      final track = (await youtube.search('rick')).first;

      final stream = await youtube.streamUrl(track);

      expect(stream?.url.scheme, 'https');
      expect(stream?.container, 'm4a');
      expect(stream?.headers, isEmpty);
    });

    test('via the uploader: the relay address, with the token', () async {
      useLocal(installed: false);
      useUploader();
      await settle();
      final track = (await youtube.search('x')).single;

      final stream = await youtube.streamUrl(track);

      expect(stream?.url.toString(), 'http://192.168.1.10:8688/api/v1/ytdlp/stream/aaaaaaaaaaa');
      expect(stream?.headers, {'Authorization': 'Bearer tok'});
    });

    test('a failure to resolve returns null and can be explained', () async {
      useLocal();
      useUploader(want: false);
      await settle();
      final track = (await youtube.search('rick')).first;
      await fake.setMode('unavailable');

      expect(await youtube.streamUrl(track), isNull);
      expect(await youtube.explainStreamFailure(track), contains('isn\'t available'));
    });
  });

  group('pictures', () {
    test('locally: straight from YouTube\'s image server, no credentials', () async {
      useLocal();
      useUploader(want: false);
      await settle();
      final track = (await youtube.search('rick')).first;

      expect(youtube.thumbnail(track).toString(), 'https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg');
      expect(youtube.imageHeaders, isEmpty);
    });

    test('via the uploader: relayed, so this device never contacts Google, with the token', () async {
      useLocal(installed: false);
      useUploader();
      await settle();
      final track = (await youtube.search('x')).single;

      expect(youtube.thumbnail(track)?.host, '192.168.1.10');
      expect(youtube.thumbnail(track)?.path, '/api/v1/ytdlp/thumb/aaaaaaaaaaa');
      expect(youtube.imageHeaders, {'Authorization': 'Bearer tok'});
    });
  });

  group('home shelves', () {
    setUp(() async {
      useLocal();
      useUploader(want: false);
      await settle();
    });

    test('hits and new releases, both on by default', () async {
      final shelves = await youtube.homeShelves();

      expect(shelves.map((s) => s.title), ['Hits on YouTube', 'New this week']);
      expect(shelves.every((s) => s.tracks.isNotEmpty), isTrue);
    });

    test('a shelf the user switched off is not fetched at all', () async {
      env.updateSettings((s) => s.youtubeShowNew = false);

      final shelves = await youtube.homeShelves();

      expect(shelves.map((s) => s.title), ['Hits on YouTube']);
      expect(fake.operations.where((o) => o.any((a) => a.startsWith('ytsearch'))), isEmpty);
    });

    test('both off: no shelves, no work', () async {
      env.updateSettings((s) {
        s.youtubeShowHits = false;
        s.youtubeShowNew = false;
      });

      expect(await youtube.homeShelves(), isEmpty);
      expect(fake.operations, isEmpty);
    });

    test('repeat visits are served from a short cache', () async {
      await youtube.homeShelves();
      final after = fake.operations.length;

      await youtube.homeShelves();

      expect(fake.operations.length, after);
    });

    test('pulling to refresh bypasses the cache', () async {
      await youtube.homeShelves();
      final after = fake.operations.length;

      await youtube.homeShelves(refresh: true);

      expect(fake.operations.length, greaterThan(after));
    });

    test('changing which shelves are on is not hidden by the cache', () async {
      await youtube.homeShelves();
      env.updateSettings((s) => s.youtubeShowHits = false);

      final shelves = await youtube.homeShelves();

      expect(shelves.map((s) => s.title), ['New this week']);
    });

    test('through the uploader, the chart comes from its trending feed', () async {
      GetIt.instance<LocalYtDlpService>().config.value = YtDlpConfig()..customBinaryPath = '${env.dir.path}/gone';
      useUploader();
      await settle();

      final shelves = await youtube.homeShelves();

      expect(shelves.first.tracks.single.name, 'Server Hit');
      expect(uploaderRequests.any((r) => r.url.path.endsWith('/trending')), isTrue);
    });
  });
}

Future<Object> _catch(Future<Object?> Function() action) async {
  try {
    await action();
  } catch (e) {
    return e;
  }
  fail('expected an error');
}
