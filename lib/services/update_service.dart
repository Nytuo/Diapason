import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.currentVersion,
    required this.notes,
    required this.releaseUrl,
    this.assetUrl,
  });

  final String version;
  final String currentVersion;

  final String notes;

  final String releaseUrl;

  final String? assetUrl;

  String get downloadUrl => assetUrl ?? releaseUrl;
}

class UpdateService {
  UpdateService({this.repo = "Nytuo/diapason"});

  final String repo;
  final _log = Logger("UpdateService");

  Uri get _latestReleaseUri => Uri.parse("https://api.github.com/repos/$repo/releases/latest");

  Future<UpdateInfo?> checkForUpdate() async {
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
      if (latest.isEmpty || !_isNewer(latest, current)) return null;

      return UpdateInfo(
        version: latest,
        currentVersion: current,
        notes: (body["body"] as String?)?.trim() ?? "",
        releaseUrl: (body["html_url"] as String?) ?? "https://github.com/$repo/releases/latest",
        assetUrl: _pickAsset(body["assets"]),
      );
    } catch (e, s) {
      _log.warning("Update check errored", e, s);
      return null;
    }
  }

  String? _pickAsset(dynamic assets) {
    if (assets is! List) return null;
    bool matches(String name) {
      final n = name.toLowerCase();
      if (Platform.isMacOS) return n.endsWith(".dmg") || n.contains("macos") || n.contains("darwin");
      if (Platform.isWindows) return n.endsWith(".exe") || n.endsWith(".msi") || n.contains("windows");
      if (Platform.isLinux) return n.endsWith(".appimage") || n.endsWith(".deb") || n.contains("linux");
      return false;
    }

    for (final asset in assets) {
      if (asset is Map && asset["name"] is String && matches(asset["name"] as String)) {
        final url = asset["browser_download_url"];
        if (url is String) return url;
      }
    }
    return null;
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
