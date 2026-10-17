import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

enum InstallStepState { pending, running, done, skipped, failed }

class InstallStep {
  InstallStep(this.label, {this.state = InstallStepState.pending, this.progress, this.note});

  String label;
  InstallStepState state;

  double? progress;
  String? note;
}

class InstallCancel {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

class InstallCancelled implements Exception {}

class YtDlpInstaller {
  YtDlpInstaller({http.Client? client}) : _http = client ?? http.Client();

  static final _log = Logger("YtDlpInstaller");
  final http.Client _http;

  static const _ytdlpApi = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest";
  static const _denoApi = "https://api.github.com/repos/denoland/deno/releases/latest";

  static String get _ytdlpAsset {
    final arm = YtDlpPaths.arch == "arm64";
    if (Platform.isMacOS) return "yt-dlp_macos";
    if (Platform.isWindows) return arm ? "yt-dlp_arm64.exe" : "yt-dlp.exe";
    return arm ? "yt-dlp_linux_aarch64" : "yt-dlp_linux";
  }

  static String get _denoAsset {
    final arm = YtDlpPaths.arch == "arm64";
    if (Platform.isMacOS) return "deno-${arm ? "aarch64" : "x86_64"}-apple-darwin.zip";
    if (Platform.isWindows) return "deno-${arm ? "aarch64" : "x86_64"}-pc-windows-msvc.zip";
    return "deno-${arm ? "aarch64" : "x86_64"}-unknown-linux-gnu.zip";
  }

  Future<String?> latestYtDlpVersion() async {
    try {
      final release = await _release(_ytdlpApi);
      return release["tag_name"] as String?;
    } catch (e) {
      _log.fine("Couldn't check the latest yt-dlp version: $e");
      return null;
    }
  }

  Future<Map<String, dynamic>> _release(String api) async {
    final response = await _http
        .get(Uri.parse(api), headers: {"Accept": "application/vnd.github+json", "User-Agent": "Diapason"})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const AppException(
        "GitHub is rate-limiting this connection. Try again in a few minutes.",
        source: ErrorSource.connection,
        code: "github_rate_limited",
      );
    }
    if (response.statusCode != 200) {
      throw AppException(
        "Couldn't look up the latest release on GitHub (HTTP ${response.statusCode}).",
        source: ErrorSource.connection,
        code: "github_http_${response.statusCode}",
      );
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  String _assetUrl(Map<String, dynamic> release, String name) {
    for (final a in (release["assets"] as List).cast<Map<String, dynamic>>()) {
      if (a["name"] == name) return a["browser_download_url"] as String;
    }
    throw AppException(
      "This release has no download for your system ($name).",
      source: ErrorSource.device,
      code: "asset_missing",
      detail: "release ${release["tag_name"]} lacks $name",
    );
  }

  Future<void> install({
    required bool ytdlp,
    required bool jsRuntime,
    required void Function(List<InstallStep>) onUpdate,
    InstallCancel? cancel,
  }) async {
    if (!await YtDlpPaths.canRunDownloadedPrograms()) {
      throw AppException(
        YtDlpPaths.execBlockedReason ?? "This build can't run downloaded programs.",
        source: ErrorSource.device,
        code: "sandbox_blocked",
      );
    }
    final steps = <InstallStep>[
      if (ytdlp) ...[
        InstallStep("Find the latest yt-dlp"),
        InstallStep("Download yt-dlp"),
        InstallStep("Verify and install yt-dlp"),
      ],
      if (jsRuntime) ...[
        InstallStep("Find the latest Deno"),
        InstallStep("Download Deno"),
        InstallStep("Verify and install Deno"),
      ],
    ];
    void emit() => onUpdate(List.of(steps));
    emit();

    var lastTick = DateTime.fromMillisecondsSinceEpoch(0);
    _tick = () {
      final now = DateTime.now();
      if (now.difference(lastTick).inMilliseconds < 100) return;
      lastTick = now;
      emit();
    };

    var i = 0;
    Future<void> run(Future<void> Function(InstallStep step) body) async {
      final step = steps[i++];
      step.state = InstallStepState.running;
      emit();
      try {
        if (cancel?.cancelled ?? false) throw InstallCancelled();
        await body(step);
        step.state = InstallStepState.done;
        step.progress = null;
      } on InstallCancelled {
        step.state = InstallStepState.failed;
        step.note = "Cancelled";
        emit();
        rethrow;
      } catch (e, stack) {
        final friendly = FriendlyError.report(_log, step.label, e, stack);
        step.state = InstallStepState.failed;
        step.note = friendly;
        emit();
        rethrow;
      }
      emit();
    }

    try {
      if (ytdlp) {
        late Map<String, dynamic> release;
        late File downloaded;
        late String expected;
        await run((step) async {
          release = await _release(_ytdlpApi);
          step.note = release["tag_name"] as String?;
        });
        await run((step) async {
          final dir = await YtDlpPaths.managedDir();
          downloaded = File(p.join(dir.path, "yt-dlp.download"));
          expected = await _expectedSha(_assetUrl(release, "SHA2-256SUMS"), _ytdlpAsset);
          await _download(_assetUrl(release, _ytdlpAsset), downloaded, step, cancel);
        });
        await run((step) async {
          await _verify(downloaded, expected);
          final target = await YtDlpPaths.managedYtDlp();
          await _makeExecutable(downloaded);
          final version = await _probe(downloaded.path, ["--version"]);
          await _replace(downloaded, target);
          step.note = "yt-dlp $version";
        });
      }

      if (jsRuntime) {
        late Map<String, dynamic> release;
        late File downloaded;
        late String expected;
        await run((step) async {
          release = await _release(_denoApi);
          step.note = release["tag_name"] as String?;
        });
        await run((step) async {
          final dir = await YtDlpPaths.managedDir();
          downloaded = File(p.join(dir.path, "deno.download"));
          final url = _assetUrl(release, _denoAsset);
          expected = _firstHash(await _text("$url.sha256sum"));
          await _download(url, downloaded, step, cancel);
        });
        await run((step) async {
          await _verify(downloaded, expected);
          final archive = ZipDecoder().decodeBytes(await downloaded.readAsBytes());
          final entry = archive.files.firstWhere(
            (f) => f.isFile && p.basename(f.name) == "deno${YtDlpPaths.exeSuffix}",
            orElse: () => throw const AppException(
              "The Deno download didn't contain the program.",
              source: ErrorSource.device,
              code: "deno_archive",
            ),
          );
          final dir = await YtDlpPaths.managedDir();
          final staged = File(p.join(dir.path, "deno.staged"));
          await staged.writeAsBytes(entry.content as List<int>, flush: true);
          await _makeExecutable(staged);
          final version = (await _probe(staged.path, ["--version"])).split("\n").first;
          await _replace(staged, await YtDlpPaths.managedDeno());
          await downloaded.delete();
          step.note = version;
        });
      }
    } on InstallCancelled {
      await _cleanup();
      rethrow;
    } catch (_) {
      await _cleanup();
      rethrow;
    }
  }

  Future<void> _cleanup() async {
    final dir = await YtDlpPaths.managedDir();
    for (final name in ["yt-dlp.download", "deno.download", "deno.staged"]) {
      final f = File(p.join(dir.path, name));
      if (f.existsSync()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }

  Future<String> _text(String url) async {
    final response = await _http
        .get(Uri.parse(url), headers: {"User-Agent": "Diapason"})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw AppException(
        "Couldn't download the checksum file (HTTP ${response.statusCode}), so the download can't be verified.",
        source: ErrorSource.connection,
        code: "checksum_missing",
        detail: "$url -> ${response.statusCode}",
      );
    }
    return utf8.decode(response.bodyBytes);
  }

  Future<String> _expectedSha(String sumsUrl, String assetName) async {
    for (final line in const LineSplitter().convert(await _text(sumsUrl))) {
      final parts = line.trim().split(RegExp(r"\s+"));
      if (parts.length >= 2 && parts.last.replaceFirst("*", "") == assetName) return _firstHash(parts.first);
    }
    throw AppException(
      "No checksum was published for $assetName, so it can't be verified.",
      source: ErrorSource.connection,
      code: "checksum_missing",
    );
  }

  static String _firstHash(String text) {
    final m = RegExp(r"\b[a-fA-F0-9]{64}\b").firstMatch(text);
    if (m == null) {
      throw const AppException(
        "The checksum file was unreadable.",
        source: ErrorSource.connection,
        code: "checksum_bad",
      );
    }
    return m.group(0)!.toLowerCase();
  }

  Future<void> _download(String url, File target, InstallStep step, InstallCancel? cancel) async {
    final request = http.Request("GET", Uri.parse(url))..headers["User-Agent"] = "Diapason";
    final response = await _http.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw AppException(
        "The download failed (HTTP ${response.statusCode}).",
        source: ErrorSource.connection,
        code: "download_http_${response.statusCode}",
        detail: url,
      );
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        if (cancel?.cancelled ?? false) throw InstallCancelled();
        sink.add(chunk);
        received += chunk.length;
        step.progress = total > 0 ? received / total : null;
        step.note = total > 0 ? "${_mb(received)} of ${_mb(total)}" : _mb(received);
        _tick?.call();
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  void Function()? _tick;

  static String _mb(int bytes) => "${(bytes / 1048576).toStringAsFixed(1)} MB";

  Future<void> _verify(File file, String expected) async {
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != expected) {
      await file.delete();
      throw AppException(
        "The download didn't match its published checksum, so it was thrown away. Try again; if it keeps failing, your network may be tampering with downloads.",
        source: ErrorSource.connection,
        code: "checksum_mismatch",
        detail: "expected $expected got $digest",
      );
    }
  }

  Future<void> _makeExecutable(File file) async {
    if (Platform.isWindows) return;
    final result = await Process.run("chmod", ["755", file.path]);
    if (result.exitCode != 0) {
      throw AppException(
        "Couldn't make the program runnable.",
        source: ErrorSource.device,
        code: "chmod_failed",
        detail: "${result.stderr}",
      );
    }
    if (Platform.isMacOS) {
      await Process.run("xattr", ["-d", "com.apple.quarantine", file.path]);
    }
  }

  Future<String> _probe(String path, List<String> args) async {
    try {
      final result = await Process.run(path, args).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0) {
        throw AppException(
          "The downloaded program wouldn't start on this computer.",
          source: ErrorSource.device,
          code: "probe_failed",
          detail: "exit ${result.exitCode}: ${result.stderr}",
        );
      }
      return "${result.stdout}".trim();
    } on ProcessException catch (e) {
      throw AppException(
        "The downloaded program wouldn't start on this computer.",
        source: ErrorSource.device,
        code: "probe_failed",
        detail: "$e",
      );
    }
  }

  Future<void> _replace(File staged, File target) async {
    final backup = File("${target.path}.old");
    if (backup.existsSync()) await backup.delete();
    if (target.existsSync()) await target.rename(backup.path);
    try {
      await staged.rename(target.path);
    } catch (_) {
      if (backup.existsSync()) await backup.rename(target.path);
      rethrow;
    }
    if (backup.existsSync()) {
      try {
        await backup.delete();
      } catch (_) {
        // Windows: still locked by a running process; harmless.
      }
    }
  }

  Future<void> removeManaged() async {
    final dir = await YtDlpPaths.managedDir();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}
