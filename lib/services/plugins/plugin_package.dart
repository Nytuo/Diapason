import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:diapason/services/plugins/plugin_manifest.dart';

class PluginPackageException implements Exception {
  PluginPackageException(this.message);

  final String message;

  @override
  String toString() => "Invalid plugin package: $message";
}

/// A plugin package read from its zip: the validated manifest and its files, all in memory, nothing written or run.
class PluginPackage {
  PluginPackage._(this.manifest, this.files, this.sha256);

  static const maxPackageBytes = 20 * 1024 * 1024;
  static const maxExtractedBytes = 50 * 1024 * 1024;
  static const maxFiles = 500;

  final PluginManifest manifest;

  /// Relative path -> contents. Always contains `manifest.json` and the manifest's `entry`.
  final Map<String, Uint8List> files;

  /// Hex digest of the zip as received.
  final String sha256;

  Uint8List get entryBytes => files[manifest.entry]!;

  /// Reads and checks a package. [expectedSha256] (from a catalog) must match when given. [appVersion] is checked
  /// against the manifest's `minAppVersion`.
  static PluginPackage read(Uint8List zipBytes, {String? expectedSha256, required String appVersion}) {
    if (zipBytes.length > maxPackageBytes) throw PluginPackageException("package is larger than 20 MiB");
    final digest = sha256OfBytes(zipBytes);
    if (expectedSha256 != null && digest != expectedSha256.toLowerCase()) {
      throw PluginPackageException("checksum mismatch (expected $expectedSha256, got $digest)");
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes, verify: true);
    } catch (e) {
      throw PluginPackageException("not a readable zip ($e)");
    }

    final files = <String, Uint8List>{};
    var total = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (entry.isSymbolicLink) throw PluginPackageException("symbolic links are not allowed (${entry.name})");
      final name = normalizeEntryName(entry.name);
      if (name == null) throw PluginPackageException("unsafe path '${entry.name}'");
      if (files.length >= maxFiles) throw PluginPackageException("more than $maxFiles files");
      total += entry.size;
      if (total > maxExtractedBytes) throw PluginPackageException("unpacks to more than 50 MiB");
      final content = entry.readBytes();
      if (content == null) throw PluginPackageException("cannot read '${entry.name}'");
      // The header's size can lie; count what was actually inflated too.
      total += content.length - entry.size;
      if (total > maxExtractedBytes) throw PluginPackageException("unpacks to more than 50 MiB");
      files[name] = content;
    }

    final manifestBytes = files["manifest.json"];
    if (manifestBytes == null) throw PluginPackageException("no manifest.json at the root");
    final manifest = PluginManifest.parseString(utf8.decode(manifestBytes, allowMalformed: true));
    if (!files.containsKey(manifest.entry)) {
      throw PluginPackageException("entry '${manifest.entry}' is not in the package");
    }
    if (compareVersions(appVersion, manifest.minAppVersion) < 0) {
      throw PluginPackageException("needs Diapason ${manifest.minAppVersion} or later (this is $appVersion)");
    }
    return PluginPackage._(manifest, Map.unmodifiable(files), digest);
  }

  /// A safe relative path, or null for absolute paths, `..`, drive letters and backslashes.
  static String? normalizeEntryName(String raw) {
    if (raw.contains("\\") || raw.contains("\u0000")) return null;
    var name = raw;
    while (name.startsWith("./")) {
      name = name.substring(2);
    }
    if (name.isEmpty || name.startsWith("/") || RegExp(r"^[A-Za-z]:").hasMatch(name)) return null;
    final parts = name.split("/");
    if (parts.any((p) => p.isEmpty || p == "." || p == "..")) return null;
    return name;
  }

  static String sha256OfBytes(List<int> bytes) => crypto.sha256.convert(bytes).toString();
}
