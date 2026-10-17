import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class YtDlpPaths {
  const YtDlpPaths._();

  static bool get isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static String get exeSuffix => Platform.isWindows ? ".exe" : "";

  static Future<Directory> managedDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, "yt-dlp-sidecar"));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> managedYtDlp() async => File(p.join((await managedDir()).path, "yt-dlp$exeSuffix"));

  static Future<File> managedDeno() async => File(p.join((await managedDir()).path, "deno$exeSuffix"));

  static String? execBlockedReason;
  static bool? _execAllowed;

  static Future<bool> canRunDownloadedPrograms() async {
    final cached = _execAllowed;
    if (cached != null) return cached;
    if (!Platform.isMacOS || !Platform.environment.containsKey("APP_SANDBOX_CONTAINER_ID")) {
      return _execAllowed = true;
    }
    final probe = File(p.join((await managedDir()).path, "exec-probe"));
    try {
      await File("/bin/sh").copy(probe.path);
      await Process.run("chmod", ["755", probe.path]);
      final result = await Process.run(probe.path, ["-c", "exit 0"]);
      _execAllowed = result.exitCode == 0;
    } on ProcessException {
      _execAllowed = false;
    } on FileSystemException {
      _execAllowed = false;
    } finally {
      try {
        if (probe.existsSync()) probe.deleteSync();
      } catch (_) {}
    }
    if (_execAllowed == false) {
      execBlockedReason =
          "This build of Diapason runs inside the macOS App Sandbox, which doesn't let it start other programs like yt-dlp. "
          "Use your diapason-uploader for YouTube instead.";
    }
    return _execAllowed!;
  }

  static String get arch {
    final v = Platform.version.toLowerCase();
    return v.contains("arm64") || v.contains("aarch64") ? "arm64" : "x64";
  }

  static List<String> get _extraDirs {
    final home = Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"] ?? "";
    if (Platform.isWindows) {
      final local = Platform.environment["LOCALAPPDATA"] ?? "";
      return [
        if (local.isNotEmpty) p.join(local, "Microsoft", "WinGet", "Links"),
        if (home.isNotEmpty) p.join(home, "scoop", "shims"),
        r"C:\ProgramData\chocolatey\bin",
        if (home.isNotEmpty) p.join(home, ".deno", "bin"),
      ];
    }
    return [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/snap/bin",
      if (home.isNotEmpty) ...[p.join(home, ".local", "bin"), p.join(home, ".deno", "bin"), p.join(home, "bin")],
    ];
  }

  @visibleForTesting
  static List<String>? searchDirsOverride;

  static String? which(String name) {
    final sep = Platform.isWindows ? ";" : ":";
    final dirs = searchDirsOverride ?? [...(Platform.environment["PATH"] ?? "").split(sep), ..._extraDirs];
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      final candidate = File(p.join(dir, "$name$exeSuffix"));
      try {
        if (candidate.existsSync()) return candidate.path;
      } catch (_) {
        // Unreadable directory (sandbox): keep looking.
      }
    }
    return null;
  }
}
