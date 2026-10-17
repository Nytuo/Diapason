import 'dart:io';

import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:diapason/services/youtube/ytdlp_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  group("command line", () {
    test("splits on spaces and honours quotes", () {
      expect(YtDlpConfig.splitArgs('--proxy "socks5://h:1" --x \'a b\' plain'), [
        "--proxy",
        "socks5://h:1",
        "--x",
        "a b",
        "plain",
      ]);
      expect(YtDlpConfig.splitArgs("  "), isEmpty);
      expect(YtDlpConfig.splitArgs('--e ""'), ["--e", ""]);
    });

    test("join and split round-trip, including awkward values", () {
      final args = ["--extractor-args", "youtube:player_client=tv,web", "--note", 'say "hi" there', "--empty", ""];
      expect(YtDlpConfig.splitArgs(YtDlpConfig.joinArgs(args)), args);
    });

    test("no shell is involved: metacharacters stay literal arguments", () {
      expect(YtDlpConfig.splitArgs(r"--x $(rm -rf ~) ; echo `id` | cat"), [
        "--x",
        r"$(rm",
        "-rf",
        "~)",
        ";",
        "echo",
        "`id`",
        "|",
        "cat",
      ]);
    });
  });

  group("config", () {
    test("visual settings become flags", () {
      final c = YtDlpConfig()
        ..proxy = "socks5://127.0.0.1:1080"
        ..cookiesFromBrowser = "firefox"
        ..rateLimit = "2M"
        ..forceIpv4 = true
        ..geoBypassCountry = "us"
        ..extractorArgs = "youtube:player_client=tv";
      final args = c.globalArgs();
      expect(args, containsAllInOrder(["--ignore-config", "--proxy", "socks5://127.0.0.1:1080"]));
      expect(args, containsAllInOrder(["--cookies-from-browser", "firefox", "--limit-rate", "2M"]));
      expect(args, contains("--force-ipv4"));
      expect(args, containsAllInOrder(["--geo-bypass-country", "US"]));
    });

    test("advanced mode replaces the visual flags entirely", () {
      final c = YtDlpConfig()
        ..proxy = "socks5://ignored"
        ..advancedMode = true
        ..advancedArgs = "--retries 9 --force-ipv6";
      expect(c.globalArgs(), ["--retries", "9", "--force-ipv6"]);
    });

    test("survives a JSON round-trip and tolerates garbage", () {
      final c = YtDlpConfig()
        ..autoUpdate = false
        ..audio = YtAudioPreference.opus
        ..advancedMode = true
        ..advancedArgs = "--x";
      final back = YtDlpConfig.decode(c.encode());
      expect(back.autoUpdate, isFalse);
      expect(back.audio, YtAudioPreference.opus);
      expect(back.advancedArgs, "--x");
      expect(YtDlpConfig.decode("{not json").autoUpdate, isTrue);
      expect(YtDlpConfig.decode(null).autoUpdate, isTrue);
    });
  });

  group("failure classification", () {
    const cases = {
      "ERROR: [youtube] x: Sign in to confirm you’re not a bot": YtFailureKind.blocked,
      "ERROR: [youtube] x: Video unavailable": YtFailureKind.unavailable,
      "ERROR: unable to download video data: HTTP Error 429: Too Many Requests": YtFailureKind.rateLimited,
      "ERROR: Unable to download webpage: Temporary failure in name resolution": YtFailureKind.network,
      "WARNING: No supported JavaScript runtime could be found": YtFailureKind.jsRuntime,
      "ERROR: [youtube] x: Requested format is not available": YtFailureKind.outdated,
      "ERROR: Sign in to confirm your age. This video may be inappropriate": YtFailureKind.ageRestricted,
      "something nobody has seen": YtFailureKind.failed,
    };
    cases.forEach((stderr, kind) {
      test(kind.code, () {
        final f = YtDlpFailure.classify(stderr);
        expect(f.kind, kind);
        expect(f.message, isNotEmpty);
        expect(f.detail, isNotEmpty);
        // The raw stderr never leaks into the sentence meant for people.
        expect(f.message, isNot(contains("ERROR:")));
      });
    });
  });

  group("video ids", () {
    test("accepts ids and the usual links", () {
      for (final input in [
        "dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=x",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?t=3",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
      ]) {
        expect(LocalYtDlpService.parseVideoId(input), "dQw4w9WgXcQ", reason: input);
      }
    });

    test("rejects everything else", () {
      for (final input in [
        "",
        "short",
        "--exec=id",
        "file:///etc/passwd",
        "https://evil.example/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/playlist?list=PL123",
      ]) {
        expect(LocalYtDlpService.parseVideoId(input), isNull, reason: input);
      }
    });
  });

  group("friendly errors", () {
    test("name the real problem, keep the technical text apart", () {
      final dns = FriendlyError.describe(const SocketException("Failed host lookup: 'nas.local'"));
      expect(dns.message, contains("find that server"));
      expect(dns.source, ErrorSource.connection);
      expect(dns.technical, contains("Failed host lookup"));

      expect(FriendlyError.message(const HandshakeException("bad cert")), contains("certificate"));
      expect(FriendlyError.describe(StateError("boom")).source, ErrorSource.unknown);
    });

    test("AppException passes its own words through", () {
      const e = AppException("Nope.", source: ErrorSource.ytdlp, code: "x", detail: "raw", requestId: "abcd");
      final d = FriendlyError.describe(e);
      expect(d.message, "Nope.");
      expect(d.technical, allOf(contains("code=x"), contains("requestId=abcd"), contains("detail=raw")));
    });
  });

  // Needs the network and a real yt-dlp on PATH: YTDLP_INTEGRATION=1 flutter test test/ytdlp_test.dart
  group("against real yt-dlp", () {
    final enabled = Platform.environment["YTDLP_INTEGRATION"] == "1";

    test("detects it, searches, resolves a stream", () async {
      final tmp = Directory.systemTemp.createTempSync("ytdlp_test");
      TestWidgetsFlutterBinding.ensureInitialized();
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      final service = LocalYtDlpService();
      await service.refresh();
      expect(service.status.value.isReady, isTrue, reason: "no yt-dlp found: ${service.status.value.problem}");

      final results = await service.search("daft punk one more time", limit: 3);
      expect(results, isNotEmpty);
      expect(results.first.id, hasLength(11));

      final stream = await service.streamUrl(results.first.id);
      expect(stream.url.scheme, "https");
      print("OK: ${results.first.title} -> ${stream.ext}, js=${service.status.value.jsRuntime}");
    }, skip: enabled ? false : "set YTDLP_INTEGRATION=1");

    // Downloads ~80 MB from GitHub into a temp folder, verifies checksums, and runs the result.
    test(
      "installer downloads, verifies and runs yt-dlp + Deno",
      () async {
        final tmp = Directory.systemTemp.createTempSync("ytdlp_install");
        TestWidgetsFlutterBinding.ensureInitialized();
        HttpOverrides.global = null; // the test binding stubs out real HTTP
        PathProviderPlatform.instance = _FakePathProvider(tmp.path);
        final service = LocalYtDlpService();
        final seen = <String>[];
        await service.installer.install(
          ytdlp: true,
          jsRuntime: true,
          onUpdate: (steps) {
            final line = steps.map((s) => "${s.state.name}:${s.label}").join(" | ");
            if (seen.isEmpty || seen.last != line) seen.add(line);
          },
        );
        expect(seen.last, isNot(contains("failed")));
        expect(seen.last, isNot(contains("pending")));
        // The managed copy is preferred over anything on PATH.
        await service.refresh();
        final s = service.status.value;
        expect(s.origin, YtDlpOrigin.managed);
        expect(s.jsRuntimeManaged, isTrue);
        expect(s.jsRuntime, "deno");
        print("installed: yt-dlp ${s.version} + ${s.jsRuntime} at ${s.path}");
        final r = await service.search("test", limit: 1);
        expect(r, isNotEmpty);
        tmp.deleteSync(recursive: true);
      },
      skip: enabled ? false : "set YTDLP_INTEGRATION=1",
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
