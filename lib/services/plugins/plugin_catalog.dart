import 'dart:convert';

import 'package:diapason/services/plugins/plugin_manifest.dart';

/// One plugin listed in a catalog. Reading a catalog never runs anything; it only says where packages are and what
/// their checksum must be.
class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.packageUrl,
    required this.sha256,
    required this.minAppVersion,
    required this.extensionPoints,
    required this.catalogUrl,
    this.problem,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final Uri? packageUrl;
  final String sha256;
  final String minAppVersion;
  final List<ExtensionPoint> extensionPoints;
  final String catalogUrl;

  /// Why it cannot be installed, if it cannot; the entry still shows in the list.
  final String? problem;

  bool get installable => problem == null;
}

class CatalogException implements Exception {
  CatalogException(this.message);

  final String message;

  @override
  String toString() => "Invalid plugin catalog: $message";
}

/// The catalog format: `{"version": 1, "name": "...", "plugins": [...]}`.
class PluginCatalog {
  const PluginCatalog({required this.url, required this.name, required this.entries});

  static const maxBytes = 1024 * 1024;
  static const maxEntries = 2000;

  final String url;
  final String name;
  final List<CatalogEntry> entries;

  /// Accepts only http(s) URLs without credentials; returns the normalised form.
  static String? normalizeUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null || !(uri.isScheme("https") || uri.isScheme("http")) || uri.host.isEmpty) return null;
    if (uri.userInfo.isNotEmpty) return null;
    return uri.removeFragment().toString();
  }

  static PluginCatalog parse(String url, List<int> bytes, {required String appVersion}) {
    if (bytes.length > maxBytes) throw CatalogException("larger than 1 MiB");
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } catch (e) {
      throw CatalogException("not JSON");
    }
    if (json is! Map) throw CatalogException("not a JSON object");
    if (json["version"] != 1) throw CatalogException("unsupported catalog version ${json["version"]}");
    final plugins = json["plugins"];
    if (plugins is! List) throw CatalogException("'plugins' is not a list");
    if (plugins.length > maxEntries) throw CatalogException("more than $maxEntries plugins");
    final base = Uri.parse(url);
    return PluginCatalog(
      url: url,
      name: json["name"] is String ? json["name"] as String : base.host,
      entries: [for (final raw in plugins) _entry(raw, base, url, appVersion)],
    );
  }

  static CatalogEntry _entry(Object? raw, Uri base, String catalogUrl, String appVersion) {
    final map = raw is Map ? raw : const <String, Object?>{};
    String s(String key) => map[key] is String ? (map[key] as String).trim() : "";
    final id = s("id");
    final packageRaw = s("package");
    // Relative package paths resolve against the catalog, so a catalog and its zips can live side by side.
    final resolved = packageRaw.isEmpty ? null : base.resolve(packageRaw);
    final packageUrl = resolved != null && normalizeUrl(resolved.toString()) != null ? resolved : null;
    final sha = s("sha256").toLowerCase();
    final minApp = s("minAppVersion").isEmpty ? "0.0.0" : s("minAppVersion");
    final points = map["extensions"] is List
        ? (map["extensions"] as List).map(ExtensionPoint.parse).nonNulls.toList()
        : <ExtensionPoint>[];

    String? problem;
    if (id.isEmpty || s("name").isEmpty || s("version").isEmpty) {
      problem = "The catalog entry is missing its id, name or version.";
    } else if (packageUrl == null) {
      problem = "The catalog entry has no usable package URL.";
    } else if (!RegExp(r"^[0-9a-f]{64}$").hasMatch(sha)) {
      problem = "The catalog entry has no valid SHA-256 checksum.";
    } else if (compareVersions(appVersion, minApp) < 0) {
      problem = "Needs Diapason $minApp or later.";
    }
    return CatalogEntry(
      id: id,
      name: s("name").isEmpty ? id : s("name"),
      version: s("version"),
      author: s("author"),
      description: s("description"),
      packageUrl: packageUrl,
      sha256: sha,
      minAppVersion: minApp,
      extensionPoints: points,
      catalogUrl: catalogUrl,
      problem: problem,
    );
  }
}
