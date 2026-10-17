import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/youtube/ytdlp_installer.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/test_env.dart';

const _ytdlpNames = ['yt-dlp_macos', 'yt-dlp_linux', 'yt-dlp_linux_aarch64', 'yt-dlp.exe', 'yt-dlp_arm64.exe'];
const _denoNames = [
  'deno-aarch64-apple-darwin.zip',
  'deno-x86_64-apple-darwin.zip',
  'deno-aarch64-unknown-linux-gnu.zip',
  'deno-x86_64-unknown-linux-gnu.zip',
  'deno-aarch64-pc-windows-msvc.zip',
  'deno-x86_64-pc-windows-msvc.zip',
];

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

List<int> _script(String body) => utf8.encode('#!/bin/sh\n$body\n');

/// A pretend GitHub: release metadata, checksum files and the downloads themselves.
class _FakeGitHub {
  _FakeGitHub()
    : ytdlp = _script('echo 2099.12.31'),
      denoZip = ZipEncoder().encode(Archive()..addFile(ArchiveFile('deno', 40, _script('echo "deno 9.9.9"')))),
      denoBinaryBytes = _script('echo "deno 9.9.9"');

  List<int> ytdlp;
  final List<int> denoZip;
  final List<int> denoBinaryBytes;

  /// Overrides, to simulate trouble.
  String? ytdlpSumsOverride;
  bool omitYtdlpSums = false;
  bool omitAssets = false;
  int apiStatus = 200;
  int downloadStatus = 200;
  Duration downloadDelay = Duration.zero;
  int chunkSize = 7;

  final requests = <String>[];

  Map<String, dynamic> _release(String tag, List<String> names) => {
    'tag_name': tag,
    'assets': omitAssets
        ? []
        : [
            for (final n in names) {'name': n, 'browser_download_url': 'https://dl.test/$tag/$n'},
          ],
  };

  Future<http.StreamedResponse> handle(http.BaseRequest request, http.ByteStream body) async {
    final url = request.url;
    requests.add(url.toString());
    http.StreamedResponse reply(int status, List<int> bytes, {Map<String, String> headers = const {}}) =>
        http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            for (var i = 0; i < bytes.length; i += chunkSize) bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length)),
          ]),
          status,
          contentLength: bytes.length,
          headers: headers,
        );

    if (url.host == 'api.github.com') {
      if (apiStatus != 200) return reply(apiStatus, utf8.encode('{"message":"nope"}'));
      if (url.path.contains('yt-dlp/yt-dlp')) {
        return reply(
          200,
          utf8.encode(jsonEncode(_release('2099.12.31', [..._ytdlpNames, if (!omitYtdlpSums) 'SHA2-256SUMS']))),
        );
      }
      return reply(
        200,
        utf8.encode(jsonEncode(_release('v9.9.9', [..._denoNames, ..._denoNames.map((n) => '$n.sha256sum')]))),
      );
    }

    final name = url.pathSegments.last;
    if (name == 'SHA2-256SUMS') {
      final lines = ytdlpSumsOverride ?? _ytdlpNames.map((n) => '${_sha(ytdlp)}  $n').join('\n');
      return reply(200, utf8.encode(lines));
    }
    if (name.endsWith('.sha256sum'))
      return reply(200, utf8.encode('${_sha(denoZip)}  ${name.replaceAll('.sha256sum', '')}'));

    if (downloadDelay > Duration.zero) await Future<void>.delayed(downloadDelay);
    if (downloadStatus != 200) return reply(downloadStatus, const []);
    if (_ytdlpNames.contains(name)) return reply(200, ytdlp);
    if (_denoNames.contains(name)) return reply(200, denoZip);
    return reply(404, const []);
  }
}

void main() {
  if (Platform.isWindows) {
    test('uses shell-script stand-ins', () {}, skip: 'POSIX only');
    return;
  }

  late TestEnv env;
  late _FakeGitHub github;
  late YtDlpInstaller installer;
  late List<List<InstallStep>> updates;

  void onUpdate(List<InstallStep> steps) =>
      updates.add([for (final s in steps) InstallStep(s.label, state: s.state, progress: s.progress, note: s.note)]);

  setUp(() async {
    env = await TestEnv.create();
    github = _FakeGitHub();
    installer = YtDlpInstaller(client: MockClient.streaming(github.handle));
    updates = [];
  });

  tearDown(() => env.dispose());

  Future<Object?> installError({bool ytdlp = true, bool deno = true, InstallCancel? cancel}) async {
    try {
      await installer.install(ytdlp: ytdlp, jsRuntime: deno, onUpdate: onUpdate, cancel: cancel);
    } catch (e) {
      return e;
    }
    return null;
  }

  group('a good install', () {
    test('downloads, verifies and installs yt-dlp and Deno, and they run', () async {
      await installer.install(ytdlp: true, jsRuntime: true, onUpdate: onUpdate);

      final ytdlp = await YtDlpPaths.managedYtDlp();
      final deno = await YtDlpPaths.managedDeno();
      expect(ytdlp.existsSync(), isTrue);
      expect(deno.existsSync(), isTrue);
      expect((await Process.run(ytdlp.path, ['--version'])).stdout.toString().trim(), '2099.12.31');
      expect((await Process.run(deno.path, ['--version'])).stdout.toString(), contains('deno 9.9.9'));
    });

    test('reports every step, ending with all done', () async {
      await installer.install(ytdlp: true, jsRuntime: true, onUpdate: onUpdate);

      expect(
        updates.first.every((s) => s.state == InstallStepState.pending || s.state == InstallStepState.running),
        isTrue,
      );
      final last = updates.last;
      expect(last, hasLength(6));
      expect(last.every((s) => s.state == InstallStepState.done), isTrue);
      expect(last.map((s) => s.label), containsAll(['Download yt-dlp', 'Download Deno']));
      expect(last.firstWhere((s) => s.label == 'Verify and install yt-dlp').note, contains('2099.12.31'));
    });

    test('download progress only ever moves forward', () async {
      github.ytdlp = _script('echo 2099.12.31\n${'#' * 400}');
      await installer.install(ytdlp: true, jsRuntime: false, onUpdate: onUpdate);

      final seen = [
        for (final u in updates)
          if (u[1].state == InstallStepState.running && u[1].progress != null) u[1].progress!,
      ];
      expect(seen, isNotEmpty);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      expect(seen.last, lessThanOrEqualTo(1.0));
    });

    test('installing only yt-dlp leaves Deno alone', () async {
      await installer.install(ytdlp: true, jsRuntime: false, onUpdate: onUpdate);

      expect((await YtDlpPaths.managedYtDlp()).existsSync(), isTrue);
      expect((await YtDlpPaths.managedDeno()).existsSync(), isFalse);
      expect(updates.last, hasLength(3));
    });

    test('leaves no download scraps behind', () async {
      await installer.install(ytdlp: true, jsRuntime: true, onUpdate: onUpdate);

      final names = (await YtDlpPaths.managedDir())
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList();
      expect(names, unorderedEquals(['yt-dlp', 'deno']));
    });

    test('an update replaces the old copy', () async {
      await installer.install(ytdlp: true, jsRuntime: false, onUpdate: onUpdate);
      github.ytdlp = _script('echo 2100.01.01');

      await installer.install(ytdlp: true, jsRuntime: false, onUpdate: onUpdate);

      final out = await Process.run((await YtDlpPaths.managedYtDlp()).path, ['--version']);
      expect(out.stdout.toString().trim(), '2100.01.01');
    });
  });

  group('safety', () {
    test('a download that does not match its published checksum is rejected and discarded', () async {
      github.ytdlpSumsOverride = _ytdlpNames.map((n) => '${'0' * 64}  $n').join('\n');

      final error = await installError(deno: false);

      expect(error, isA<AppException>().having((e) => e.code, 'code', 'checksum_mismatch'));
      expect((await YtDlpPaths.managedYtDlp()).existsSync(), isFalse, reason: 'never made executable');
      expect((await YtDlpPaths.managedDir()).listSync(), isEmpty, reason: 'and the bad file is gone');
      expect(updates.last.last.state, InstallStepState.failed);
    });

    test('a failed update keeps the working copy that was already installed', () async {
      await installer.install(ytdlp: true, jsRuntime: false, onUpdate: onUpdate);
      github.ytdlp = _script('echo 2100.01.01');
      github.ytdlpSumsOverride = _ytdlpNames.map((n) => '${'f' * 64}  $n').join('\n');

      await installError(deno: false);

      final out = await Process.run((await YtDlpPaths.managedYtDlp()).path, ['--version']);
      expect(out.stdout.toString().trim(), '2099.12.31');
    });

    test('no published checksum means no install (fail closed)', () async {
      github.ytdlpSumsOverride = 'abc  some_other_file';

      final error = await installError(deno: false);

      expect(error, isA<AppException>().having((e) => e.code, 'code', 'checksum_missing'));
      expect((await YtDlpPaths.managedYtDlp()).existsSync(), isFalse);
    });

    test('a release without a checksum file is refused', () async {
      github.omitYtdlpSums = true;

      final error = await installError(deno: false);

      expect(error, isA<AppException>().having((e) => e.code, 'code', 'asset_missing'));
    });

    test('a download that cannot start on this computer is caught before it replaces anything', () async {
      github.ytdlp = _script('exit 3');

      final error = await installError(deno: false);

      expect(error, isA<AppException>().having((e) => e.code, 'code', 'probe_failed'));
      expect((await YtDlpPaths.managedYtDlp()).existsSync(), isFalse);
    });

    test('a zip without the program inside is refused', () async {
      final bad = ZipEncoder().encode(Archive()..addFile(ArchiveFile('README', 3, utf8.encode('hi'))));
      final h = _FakeGitHub();
      final client = MockClient.streaming((req, body) async {
        final res = await h.handle(req, body);
        if (req.url.pathSegments.last.endsWith('.zip') || req.url.pathSegments.last.endsWith('.sha256sum')) {
          final data = req.url.pathSegments.last.endsWith('.sha256sum') ? utf8.encode('${_sha(bad)}  x') : bad;
          return http.StreamedResponse(Stream.value(data), 200, contentLength: data.length);
        }
        return res;
      });

      final error = await (() async {
        try {
          await YtDlpInstaller(client: client).install(ytdlp: false, jsRuntime: true, onUpdate: onUpdate);
        } catch (e) {
          return e;
        }
        return null;
      })();

      expect(error, isA<AppException>().having((e) => e.code, 'code', 'deno_archive'));
    });
  });

  group('trouble with GitHub', () {
    test('rate limiting is explained, not shown as a bare HTTP code', () async {
      github.apiStatus = 403;

      final error = await installError();

      expect(error, isA<AppException>().having((e) => e.code, 'code', 'github_rate_limited'));
      expect(FriendlyError.message(error), contains('rate-limiting'));
    });

    test('a failing download is reported with a stable code and a sentence a person can read', () async {
      github.downloadStatus = 500;

      final error = await installError(deno: false) as AppException;

      expect(error.code, 'download_http_500');
      expect(error.source, ErrorSource.connection);
      expect(error.message, contains('download'));
      expect(error.detail, contains('dl.test'), reason: 'the URL helps a bug report');
    });

    test('a release that has no build for this system says so', () async {
      github.omitAssets = true;

      final error = await installError();

      expect(error, isA<AppException>().having((e) => e.code, 'code', 'asset_missing'));
    });

    test('latestYtDlpVersion returns the tag, or null when GitHub is unreachable', () async {
      expect(await installer.latestYtDlpVersion(), '2099.12.31');

      github.apiStatus = 500;
      expect(await installer.latestYtDlpVersion(), isNull);
    });
  });

  group('cancelling', () {
    test('stops mid-download, cleans up and installs nothing', () async {
      github.chunkSize = 2;
      github.ytdlp = _script('echo 2099.12.31\n${'#' * 4000}');
      final cancel = InstallCancel();
      var requested = false;
      final client = MockClient.streaming((req, body) async {
        final res = await github.handle(req, body);
        if (_ytdlpNames.contains(req.url.pathSegments.last)) {
          requested = true;
          // Cancel as soon as bytes start flowing.
          return http.StreamedResponse(
            res.stream.map((chunk) {
              cancel.cancel();
              return chunk;
            }),
            res.statusCode,
            contentLength: res.contentLength,
          );
        }
        return res;
      });

      Object? error;
      try {
        await YtDlpInstaller(client: client).install(ytdlp: true, jsRuntime: false, onUpdate: onUpdate, cancel: cancel);
      } catch (e) {
        error = e;
      }

      expect(requested, isTrue);
      expect(error, isA<InstallCancelled>());
      expect((await YtDlpPaths.managedYtDlp()).existsSync(), isFalse);
      expect((await YtDlpPaths.managedDir()).listSync(), isEmpty);
    });
  });

  group('removal', () {
    test('removeManaged deletes both programs', () async {
      await installer.install(ytdlp: true, jsRuntime: true, onUpdate: onUpdate);

      await installer.removeManaged();

      expect((await YtDlpPaths.managedYtDlp()).existsSync(), isFalse);
      expect((await YtDlpPaths.managedDeno()).existsSync(), isFalse);
    });
  });
}
