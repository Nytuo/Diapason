import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.currentVersion,
    required this.notes,
    required this.releaseUrl,
    this.assetUrl,
    this.force = false,
  });

  final String version;
  final String currentVersion;

  final String notes;

  final String releaseUrl;

  final String? assetUrl;

  /// Whether this update is mandatory. Set by putting a `[force]` marker
  /// anywhere in the GitHub release notes; the update dialog then can't be
  /// dismissed until the user updates.
  final bool force;

  String get downloadUrl => assetUrl ?? releaseUrl;
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class UpdateService {
  UpdateService({this.repo = "Nytuo/diapason"});

  final String repo;
  final _log = Logger("UpdateService");

  /// Marker in the release notes that makes an update mandatory, e.g. `[force]`
  /// or `[force-update]`. Matched case-insensitively and stripped from the
  /// notes shown to the user.
  static final _forceMarker = RegExp(r"\[force(?:[-_ ]?update)?\]", caseSensitive: false);

  Uri get _latestReleaseUri => Uri.parse("https://api.github.com/repos/$repo/releases/latest");

  /// When [ignoreVersion] is true, the latest release is returned even if it
  /// isn't newer than the installed build — used by the "reinstall latest"
  /// action to force a re-download of the current version.
  Future<UpdateInfo?> checkForUpdate({bool ignoreVersion = false}) async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version;

      final response = await http
          .get(_latestReleaseUri, headers: const {"Accept": "application/vnd.github+json"})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        _log.warning("Update check failed: HTTP ${response.statusCode}");
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body["draft"] == true || body["prerelease"] == true) return null;

      final tag = (body["tag_name"] as String?)?.trim() ?? "";
      final latest = _stripV(tag);
      if (latest.isEmpty) return null;
      if (!ignoreVersion && !_isNewer(latest, current)) return null;

      final rawNotes = (body["body"] as String?)?.trim() ?? "";
      final force = _forceMarker.hasMatch(rawNotes);

      return UpdateInfo(
        version: latest,
        currentVersion: current,
        notes: rawNotes.replaceAll(_forceMarker, "").trim(),
        releaseUrl: (body["html_url"] as String?) ?? "https://github.com/$repo/releases/latest",
        assetUrl: _pickAsset(body["assets"]),
        force: force,
      );
    } catch (e, s) {
      _log.warning("Update check errored", e, s);
      return null;
    }
  }

  /// The arch tokens our release assets carry (see the
  /// `diapason-<version>_<os>_<arch>.<ext>` naming scheme). Ordered by preference:
  /// the running machine's native arch first, then any compatible fallback (an
  /// x64 build runs fine under emulation on arm64 Windows/macOS).
  static List<String> get _archTokens {
    switch (Abi.current()) {
      case Abi.windowsArm64:
      case Abi.linuxArm64:
      case Abi.macosArm64:
        return const ["aarch64", "arm64", "x64", "x86_64", "amd64"];
      default:
        return const ["x64", "x86_64", "amd64"];
    }
  }

  String? _pickAsset(dynamic assets) {
    if (assets is! List) return null;
    bool matches(String name) {
      final n = name.toLowerCase();
      if (Platform.isAndroid) return n.endsWith(".apk");
      if (Platform.isMacOS) return n.endsWith(".dmg") || n.endsWith(".pkg") || n.contains("macos") || n.contains("darwin");
      if (Platform.isWindows) return n.endsWith(".exe") || n.endsWith(".msi") || n.contains("windows") || n.contains("_win_");
      if (Platform.isLinux) return n.endsWith(".appimage") || n.endsWith(".deb") || n.contains("linux");
      return false;
    }

    String? url(dynamic asset) {
      final u = asset is Map ? asset["browser_download_url"] : null;
      return u is String ? u : null;
    }

    // Collect every platform-appropriate asset, then prefer one whose name
    // carries this machine's architecture token before falling back to any.
    // Android ships a single universal APK, so arch matching is skipped there.
    final candidates = <String, String>{}; // name(lowercased) -> url
    for (final asset in assets) {
      if (asset is Map && asset["name"] is String && matches(asset["name"] as String)) {
        final u = url(asset);
        if (u != null) candidates[(asset["name"] as String).toLowerCase()] = u;
      }
    }
    if (candidates.isEmpty) return null;
    if (!Platform.isAndroid) {
      for (final token in _archTokens) {
        for (final entry in candidates.entries) {
          if (entry.key.contains(token)) return entry.value;
        }
      }
    }
    return candidates.values.first;
  }

  /// Whether [url]'s installer can be downloaded and launched from inside the
  /// app. Android hands the APK to the package installer; Windows and macOS run
  /// the downloaded installer. Linux ships as .deb/flatpak/snap, which can't be
  /// installed unattended, so it falls back to opening the release page.
  static bool canInstallInApp(String? assetUrl) =>
      assetUrl != null && (Platform.isAndroid || Platform.isWindows || Platform.isMacOS);

  /// Downloads the installer at [url] and launches it.
  ///
  /// Supported on Android, Windows and macOS (see [canInstallInApp]).
  /// [onProgress] is called with a value in `0.0..1.0`, or `null` when the
  /// server doesn't report a content length. Throws [UpdateException] on any
  /// failure; the caller is responsible for surfacing errors.
  Future<void> downloadAndInstall(String url, {void Function(double? progress)? onProgress}) async {
    if (!canInstallInApp(url)) {
      throw const UpdateException("In-app install isn't supported on this platform.");
    }

    if (Platform.isAndroid && !await _ensureInstallPermission()) {
      throw const UpdateException(
        "Permission to install apps was not granted. Enable it for Diapason in "
        "system settings and try again.",
      );
    }

    try {
      final file = await _download(url, onProgress: onProgress);
      await _launchInstaller(file);
    } on UpdateException {
      rethrow;
    } catch (e, s) {
      _log.warning("Update download/install failed", e, s);
      throw UpdateException("Update failed: $e");
    }
  }

  /// Streams [url] to a file and returns it. On Android the file must live where
  /// our FileProvider (see filepaths.xml) can expose it to the installer; on
  /// desktop the temp dir is fine.
  Future<File> _download(String url, {void Function(double? progress)? onProgress}) async {
    final client = http.Client();
    try {
      final request = http.Request("GET", Uri.parse(url));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw UpdateException("Download failed: HTTP ${response.statusCode}");
      }

      final Directory dir = Platform.isAndroid
          ? (await getExternalStorageDirectory() ?? await getTemporaryDirectory())
          : await getTemporaryDirectory();
      final file = File("${dir.path}/${_installerFileName(url)}");
      if (await file.exists()) {
        await file.delete();
      }

      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(total != null && total > 0 ? received / total : null);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      return file;
    } finally {
      client.close();
    }
  }

  /// A safe local filename for the downloaded installer, keeping the original
  /// extension so the OS knows how to run it.
  String _installerFileName(String url) {
    if (Platform.isAndroid) return "diapason-update.apk";
    final segments = Uri.parse(url).pathSegments;
    final last = segments.isEmpty ? "" : segments.last;
    final sanitized = last.replaceAll(RegExp(r"[^A-Za-z0-9._-]"), "_");
    return sanitized.isEmpty ? "diapason-update" : sanitized;
  }

  Future<void> _launchInstaller(File file) async {
    final path = file.path;
    if (Platform.isAndroid) {
      final result = await OpenFilex.open(path, type: "application/vnd.android.package-archive");
      if (result.type != ResultType.done) {
        throw UpdateException("Could not open the installer: ${result.message}");
      }
      return;
    }
    if (Platform.isWindows) {
      // .msi installs via msiexec; .exe installers run directly. Detached so it
      // outlives this process, letting the installer replace app files.
      if (path.toLowerCase().endsWith(".msi")) {
        await Process.start("msiexec", ["/i", path], mode: ProcessStartMode.detached);
      } else {
        await Process.start(path, const [], mode: ProcessStartMode.detached);
      }
      // Quit so the installer can overwrite the running executable. The short
      // delay gives the detached process time to spawn before we exit.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
    if (Platform.isMacOS) {
      // Mounts the .dmg (or opens the .pkg); the user completes the install.
      await Process.start("open", [path], mode: ProcessStartMode.detached);
      return;
    }
    throw const UpdateException("In-app install isn't supported on this platform.");
  }

  Future<bool> _ensureInstallPermission() async {
    final status = await Permission.requestInstallPackages.status;
    if (status.isGranted) return true;
    final result = await Permission.requestInstallPackages.request();
    return result.isGranted;
  }

  static String _stripV(String tag) => tag.startsWith("v") ? tag.substring(1) : tag;

  static bool _isNewer(String candidate, String current) {
    List<int> parse(String v) => v
        .split(RegExp(r"[-+]"))
        .first
        .split(".")
        .map((p) => int.tryParse(p.replaceAll(RegExp(r"[^0-9]"), "")) ?? 0)
        .toList();

    final a = parse(candidate);
    final b = parse(current);
    final len = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final ai = i < a.length ? a[i] : 0;
      final bi = i < b.length ? b[i] : 0;
      if (ai != bi) return ai > bi;
    }
    return false;
  }
}
