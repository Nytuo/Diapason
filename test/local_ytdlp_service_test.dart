import 'dart:io';

import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:diapason/services/youtube/ytdlp_errors.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ytdlp.dart';
import 'support/test_env.dart';

/// Drives the real [LocalYtDlpService] against a fake yt-dlp executable.
void main() {
  if (!FakeYtDlp.supported) {
    test('needs a POSIX shell', () {}, skip: 'fake yt-dlp is a shell script');
    return;
  }

  late TestEnv env;
  late FakeYtDlp fake;
  late LocalYtDlpService service;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    fake = await FakeYtDlp.create(env.dir);
    // Look nowhere else: a yt-dlp installed on the developer's machine must not leak in.
    YtDlpPaths.searchDirsOverride = [];
    YtDlpPaths.execBlockedReason = null;
    service = LocalYtDlpService();
    service.config.value = YtDlpConfig()..customBinaryPath = fake.path;
  });

  tearDown(() async {
    YtDlpPaths.searchDirsOverride = null;
    await env.dispose();
  });

  group('detection', () {
    test('finds a custom executable and reports its version', () async {
      await service.refresh();

      final s = service.status.value;
      expect(s.state, LocalYtDlpState.ready);
      expect(s.version, '2099.01.01');
      expect(s.origin, YtDlpOrigin.custom);
      expect(s.path, fake.path);
    });

    test('a managed copy is used when no custom path is set', () async {
      final managed = await YtDlpPaths.managedYtDlp();
      await fake.script.copy(managed.path);
      await Process.run('chmod', ['755', managed.path]);
      service.config.value = YtDlpConfig();

      await service.refresh();

      expect(service.status.value.origin, YtDlpOrigin.managed);
    });

    test('a custom path that does not exist falls through to "not installed"', () async {
      service.config.value = YtDlpConfig()..customBinaryPath = '${env.dir.path}/nope';

      await service.refresh();

      expect(service.status.value.state, LocalYtDlpState.notInstalled);
    });

    test('a file that is not a program is reported broken, with a reason', () async {
      final junk = File('${env.dir.path}/junk')..writeAsStringSync('not executable');
      service.config.value = YtDlpConfig()..customBinaryPath = junk.path;

      await service.refresh();

      expect(service.status.value.state, LocalYtDlpState.broken);
      expect(service.status.value.problem, isNotEmpty);
    });

    test('Deno next to yt-dlp is found and passed along as the JS runtime', () async {
      final deno = await YtDlpPaths.managedDeno();
      await fake.script.copy(deno.path); // any executable will do for detection
      await Process.run('chmod', ['755', deno.path]);

      await service.refresh();
      await service.search('anything');

      expect(service.status.value.jsRuntime, 'deno');
      expect(service.status.value.jsRuntimeManaged, isTrue);
      final args = fake.operations.single;
      expect(args, containsAllInOrder(['--js-runtimes', 'deno:${deno.path}']));
    });

    test('a JS runtime of "none" is respected', () async {
      final deno = await YtDlpPaths.managedDeno();
      await fake.script.copy(deno.path);
      service.config.value = YtDlpConfig()
        ..customBinaryPath = fake.path
        ..jsRuntime = 'none';

      await service.refresh();
      await service.search('x');

      expect(service.status.value.jsRuntime, isNull);
      expect(fake.operations.single, isNot(contains('--js-runtimes')));
    });
  });

  group('before it is installed', () {
    test('every operation fails with a clear, actionable error', () async {
      service.config.value = YtDlpConfig();
      await service.refresh();

      expect(
        () => service.search('x'),
        throwsA(isA<YtDlpFailure>().having((e) => e.kind, 'kind', YtFailureKind.notInstalled)),
      );
    });
  });

  group('operations', () {
    setUp(() => service.refresh());

    test('search parses videos, drops channels and malformed ids, tidies artist names', () async {
      final results = await service.search('rick', limit: 5);

      expect(results.map((e) => e.id), ['dQw4w9WgXcQ', '9bZkp7q19f0']);
      expect(results.first.artist, 'Rick Astley', reason: '" - Topic" is YouTube Music noise');
      expect(results.first.durationSecs, 212);
      expect(results.last.artist, 'officialpsy');
    });

    test('search sends the query only after "--", so it can never act as a flag', () async {
      await service.search('--exec=touch /tmp/pwned');

      final args = fake.operations.single;
      final dashDash = args.indexOf('--');
      expect(dashDash, greaterThan(0));
      expect(args.sublist(dashDash + 1), ['ytsearch20:--exec=touch /tmp/pwned']);
      expect(args.sublist(0, dashDash), isNot(contains('--exec=touch /tmp/pwned')));
    });

    test('an empty search does not start a process', () async {
      expect(await service.search('   '), isEmpty);
      expect(fake.operations, isEmpty);
    });

    test('lookup reads one video', () async {
      final entry = await service.lookup('jNQXAC9IVRw');

      expect(entry?.title, 'Me at the zoo');
      expect(entry?.artist, 'jawed');
      expect(entry?.durationSecs, 19);
    });

    test('lookup refuses anything that is not a video id', () async {
      expect(await service.lookup('--exec=id'), isNull);
      expect(fake.operations, isEmpty);
    });

    test('related excludes the seed video itself', () async {
      final related = await service.related('jNQXAC9IVRw');

      expect(related.map((e) => e.id), isNot(contains('jNQXAC9IVRw')));
      expect(related, isNotEmpty);
    });

    test('playlist reads entries with a limit', () async {
      final entries = await service.playlist('https://www.youtube.com/playlist?list=PL1', limit: 7);

      expect(entries, hasLength(2));
      expect(fake.operations.single, containsAllInOrder(['--playlist-end', '7']));
    });

    test('streamUrl returns an https address and the container, and is cached briefly', () async {
      final first = await service.streamUrl('dQw4w9WgXcQ');
      final second = await service.streamUrl('dQw4w9WgXcQ');

      expect(first.url.scheme, 'https');
      expect(first.ext, 'm4a');
      expect(second.url, first.url);
      expect(fake.operations, hasLength(1), reason: 'the second play must not spawn yt-dlp again');
    });

    test('the chosen audio format reaches yt-dlp', () async {
      service.config.value = YtDlpConfig()
        ..customBinaryPath = fake.path
        ..audio = YtAudioPreference.opus;

      await service.streamUrl('dQw4w9WgXcQ');

      expect(fake.operations.single, containsAllInOrder(['-f', YtAudioPreference.opus.format]));
    });

    test('streamUrl on a bad id fails without running anything', () async {
      expect(
        () => service.streamUrl('nope'),
        throwsA(isA<YtDlpFailure>().having((e) => e.kind, 'kind', YtFailureKind.badTarget)),
      );
      expect(fake.operations, isEmpty);
    });

    test('unparseable output becomes an error, not a crash', () async {
      await fake.setMode('garbage');

      expect(() => service.search('x'), throwsA(isA<FormatException>()));
    });
  });

  group('failures say what really went wrong', () {
    setUp(() => service.refresh());

    Future<YtDlpFailure> failing(String mode) async {
      await fake.setMode(mode);
      try {
        await service.search('x');
      } on YtDlpFailure catch (e) {
        return e;
      }
      fail('expected a YtDlpFailure for mode $mode');
    }

    test('bot check', () async {
      final e = await failing('bot');
      expect(e.kind, YtFailureKind.blocked);
      expect(e.message, contains('bot'));
      expect(e.message, isNot(contains('ERROR')), reason: 'raw stderr belongs in details only');
      expect(e.detail, contains('Sign in to confirm'));
    });

    test('unavailable video', () async {
      expect((await failing('unavailable')).kind, YtFailureKind.unavailable);
    });

    test('network trouble', () async {
      expect((await failing('network')).kind, YtFailureKind.network);
    });

    test('a hung process is stopped at the timeout', () async {
      await fake.setMode('slow');
      final watch = Stopwatch()..start();

      await expectLater(
        service.run(['ytsearch1:x'], timeout: const Duration(milliseconds: 150)),
        throwsA(isA<YtDlpFailure>().having((e) => e.kind, 'kind', YtFailureKind.timeout)),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  group('settings reach the command line', () {
    setUp(() => service.refresh());

    test('visual settings become flags', () async {
      service.config.value = YtDlpConfig()
        ..customBinaryPath = fake.path
        ..proxy = 'socks5://127.0.0.1:1080'
        ..rateLimit = '2M'
        ..forceIpv4 = true;

      await service.search('x');

      final args = fake.operations.single;
      expect(args, containsAllInOrder(['--proxy', 'socks5://127.0.0.1:1080']));
      expect(args, containsAllInOrder(['--limit-rate', '2M']));
      expect(args, contains('--force-ipv4'));
      expect(args, contains('--ignore-config'));
    });

    test('advanced mode replaces the visual flags entirely', () async {
      service.config.value = YtDlpConfig()
        ..customBinaryPath = fake.path
        ..proxy = 'socks5://ignored'
        ..advancedMode = true
        ..advancedArgs = '--retries 9 --some-flag "with space"';

      await service.search('x');

      final args = fake.operations.single;
      expect(args, containsAllInOrder(['--retries', '9', '--some-flag', 'with space']));
      expect(args, isNot(contains('--proxy')));
      expect(args, isNot(contains('--ignore-config')), reason: 'in advanced mode the user owns the flags');
    });

    test('the settings preview shows the command that will really run', () async {
      final preview = service.previewCommand(['--no-playlist', '--', 'https://www.youtube.com/watch?v=x']);

      expect(preview, startsWith(fake.path));
      expect(preview, contains('--ignore-config'));
      expect(preview, endsWith('https://www.youtube.com/watch?v=x'));
    });

    test('saving settings persists them and re-detects', () async {
      await service.saveConfig(
        YtDlpConfig()
          ..customBinaryPath = fake.path
          ..retries = 11,
      );

      expect(YtDlpConfig.decode(FinampSettingsHelper.finampSettings.ytdlpConfigJson).retries, 11);
      expect(service.status.value.isReady, isTrue);
    });
  });

  group('concurrency', () {
    test('never runs more than three yt-dlp processes at once', () async {
      await service.refresh();
      await fake.setMode('slow');

      await Future.wait([
        for (var i = 0; i < 8; i++) service.run(['ytsearch1:x$i']),
      ]);

      var running = 0, peak = 0;
      for (final line in fake.timeline) {
        running += line.startsWith('start') ? 1 : -1;
        if (running > peak) peak = running;
      }
      expect(fake.timeline.where((l) => l.startsWith('start')), hasLength(8), reason: 'all of them still ran');
      expect(peak, lessThanOrEqualTo(3));
      expect(peak, greaterThan(1), reason: 'and they did overlap, so it is not fully serialised');
    });
  });
}
