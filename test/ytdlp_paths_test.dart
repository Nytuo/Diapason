import 'dart:io';

import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() async {
    YtDlpPaths.searchDirsOverride = null;
    YtDlpPaths.execBlockedReason = null;
    await env.dispose();
  });

  group('finding programs on this machine', () {
    test('looks only where it is told to, in order', () async {
      final a = await Directory(p.join(env.dir.path, 'a')).create();
      final b = await Directory(p.join(env.dir.path, 'b')).create();
      File(p.join(b.path, 'yt-dlp${YtDlpPaths.exeSuffix}')).writeAsStringSync('b');
      YtDlpPaths.searchDirsOverride = [a.path, b.path];

      expect(YtDlpPaths.which('yt-dlp'), p.join(b.path, 'yt-dlp${YtDlpPaths.exeSuffix}'));

      File(p.join(a.path, 'yt-dlp${YtDlpPaths.exeSuffix}')).writeAsStringSync('a');
      expect(
        YtDlpPaths.which('yt-dlp'),
        p.join(a.path, 'yt-dlp${YtDlpPaths.exeSuffix}'),
        reason: 'earlier directory wins',
      );
    });

    test('says nothing when it is not there, and ignores missing or empty directories', () {
      YtDlpPaths.searchDirsOverride = ['', '${env.dir.path}/nope'];

      expect(YtDlpPaths.which('yt-dlp'), isNull);
    });

    test('reports the CPU family as one of the two the downloads are built for', () {
      expect(YtDlpPaths.arch, anyOf('arm64', 'x64'));
    });
  });

  group('where the managed copies live', () {
    test('inside the app\'s own support folder, created on demand', () async {
      final dir = await YtDlpPaths.managedDir();

      expect(dir.existsSync(), isTrue);
      expect(dir.path, startsWith(p.join(env.dir.path, 'support')));
      expect((await YtDlpPaths.managedYtDlp()).path, p.join(dir.path, 'yt-dlp${YtDlpPaths.exeSuffix}'));
      expect((await YtDlpPaths.managedDeno()).path, p.join(dir.path, 'deno${YtDlpPaths.exeSuffix}'));
    });
  });

  group('whether this build may run downloaded programs', () {
    test('a normal (unsandboxed) build may', () async {
      if (Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID')) return;

      expect(await YtDlpPaths.canRunDownloadedPrograms(), isTrue);
      expect(YtDlpPaths.execBlockedReason, isNull);
      expect(LocalYtDlpService.supported, YtDlpPaths.isDesktop);
    });

    test('a blocked build turns local yt-dlp off cleanly instead of failing at every call', () async {
      YtDlpPaths.execBlockedReason = 'This build runs inside the macOS App Sandbox.';

      expect(LocalYtDlpService.supported, isFalse);
      final service = LocalYtDlpService();
      await service.refresh(); // returns straight away: nothing to detect when unsupported

      expect(service.status.value.isReady, isFalse);
    });
  });
}
