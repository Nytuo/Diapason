import 'dart:convert';

/// The manifest format this Diapason reads. A package written for a later format is refused, not half-loaded.
const int pluginManifestVersion = 1;

/// How a plugin's code runs.
enum PluginRuntimeKind {
  /// No code: request templates and JSON paths, interpreted by the host (`handlers.json`).
  declarative,

  /// A WebAssembly module, interpreted in pure Dart in a worker isolate (`plugin.wasm`).
  wasm;

  static PluginRuntimeKind? parse(Object? value) => values.where((v) => v.name == value).firstOrNull;
}

/// Where a plugin plugs into the app. Each one maps to a typed Dart interface in `extension_points.dart`.
enum ExtensionPoint {
  lyrics("lyrics"),
  coverArt("cover_art"),
  metadata("metadata"),
  radioDirectory("radio_directory"),
  scrobbler("scrobbler"),
  source("source"),
  command("command");

  const ExtensionPoint(this.wireName);

  /// The name used in manifests.
  final String wireName;

  static ExtensionPoint? parse(Object? value) => values.where((v) => v.wireName == value).firstOrNull;
}

/// Which items a command applies to.
enum CommandTarget {
  track,
  album,
  artist;

  static CommandTarget? parse(Object? value) => values.where((v) => v.name == value).firstOrNull;
}

/// Something a plugin asks to be allowed to do. What is not declared cannot be done: there is no catch-all.
sealed class PluginPermission {
  const PluginPermission();

  /// The manifest's `type`.
  String get type;

  Map<String, Object?> toJson();

  static const knownTypes = {"network", "storage", "playback_control", "now_playing", "library_read"};

  /// Null and an error when the entry is not understood: unknown permissions fail closed.
  static (PluginPermission?, String?) parse(Object? json) {
    if (json is! Map) return (null, "a permission is not an object");
    final type = json["type"];
    switch (type) {
      case "network":
        final hosts = json["hosts"];
        if (hosts is! List || hosts.isEmpty) return (null, "network permission needs a non-empty 'hosts' list");
        final parsed = <String>[];
        for (final host in hosts) {
          if (host is! String || !NetworkPermission.isValidHostPattern(host)) {
            return (null, "invalid network host '$host'");
          }
          parsed.add(host.toLowerCase());
        }
        return (NetworkPermission(parsed), null);
      case "storage":
        return (const StoragePermission(), null);
      case "playback_control":
        return (const PlaybackControlPermission(), null);
      case "now_playing":
        return (const NowPlayingPermission(), null);
      case "library_read":
        return (const LibraryReadPermission(), null);
      default:
        return (null, "unknown permission type '$type'");
    }
  }

  @override
  bool operator ==(Object other) => other is PluginPermission && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Reach these hosts over HTTPS, through the host's fetch. `*.example.com` covers subdomains, not `example.com`.
class NetworkPermission extends PluginPermission {
  NetworkPermission(List<String> hosts) : hosts = List.unmodifiable(hosts);

  final List<String> hosts;

  @override
  String get type => "network";

  @override
  Map<String, Object?> toJson() => {"type": type, "hosts": hosts};

  static final _label = RegExp(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$");

  /// A DNS name, optionally starting with `*.`; no bare `*`, no IP wildcards, no ports or schemes.
  static bool isValidHostPattern(String host) {
    var name = host.toLowerCase();
    if (name.startsWith("*.")) name = name.substring(2);
    if (name.isEmpty || name.length > 253) return false;
    final labels = name.split(".");
    if (labels.length < 2) return false;
    return labels.every(_label.hasMatch);
  }

  /// Whether [host] is one of [hosts].
  bool allows(String host) {
    final name = host.toLowerCase();
    for (final pattern in hosts) {
      if (pattern.startsWith("*.")) {
        if (name.endsWith(pattern.substring(1)) && name.length > pattern.length - 1) return true;
      } else if (name == pattern) {
        return true;
      }
    }
    return false;
  }
}

/// Keep a small key-value store of its own.
class StoragePermission extends PluginPermission {
  const StoragePermission();
  @override
  String get type => "storage";
  @override
  Map<String, Object?> toJson() => {"type": type};
}

/// Play, pause and skip.
class PlaybackControlPermission extends PluginPermission {
  const PlaybackControlPermission();
  @override
  String get type => "playback_control";
  @override
  Map<String, Object?> toJson() => {"type": type};
}

/// See the track that is playing.
class NowPlayingPermission extends PluginPermission {
  const NowPlayingPermission();
  @override
  String get type => "now_playing";
  @override
  Map<String, Object?> toJson() => {"type": type};
}

/// Search the library, read-only.
class LibraryReadPermission extends PluginPermission {
  const LibraryReadPermission();
  @override
  String get type => "library_read";
  @override
  Map<String, Object?> toJson() => {"type": type};
}

/// One thing a plugin provides.
class PluginExtension {
  const PluginExtension({required this.point, this.id, this.title, this.targets = const []});

  final ExtensionPoint point;

  /// For commands: the command's id, passed back on `command.run`.
  final String? id;

  /// For commands: the menu label. For providers: an optional display name.
  final String? title;

  /// For commands: which items show it.
  final List<CommandTarget> targets;

  Map<String, Object?> toJson() => {
    "point": point.wireName,
    "id": ?id,
    "title": ?title,
    if (targets.isNotEmpty) "targets": [for (final t in targets) t.name],
  };
}

class ManifestException implements Exception {
  ManifestException(this.errors);

  final List<String> errors;

  @override
  String toString() => "Invalid plugin manifest: ${errors.join("; ")}";
}

/// What a plugin says about itself, validated whole before anything loads.
class PluginManifest {
  PluginManifest._({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.homepage,
    required this.minAppVersion,
    required this.runtime,
    required this.entry,
    required this.permissions,
    required this.extensions,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String? homepage;
  final String minAppVersion;
  final PluginRuntimeKind runtime;

  /// Path of the code (WASM) or handlers (declarative) file inside the package.
  final String entry;
  final List<PluginPermission> permissions;
  final List<PluginExtension> extensions;

  static final _idPattern = RegExp(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$");
  static final _versionPattern = RegExp(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$");
  static final _entryPattern = RegExp(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$");

  NetworkPermission? get network => permissions.whereType<NetworkPermission>().firstOrNull;

  bool has<T extends PluginPermission>() => permissions.whereType<T>().isNotEmpty;

  bool provides(ExtensionPoint point) => extensions.any((e) => e.point == point);

  Iterable<PluginExtension> commands() => extensions.where((e) => e.point == ExtensionPoint.command);

  static PluginManifest parseString(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (e) {
      throw ManifestException(["manifest.json is not valid JSON: ${e.message}"]);
    }
    return parse(json);
  }

  /// Validates everything and throws a [ManifestException] listing every problem found.
  static PluginManifest parse(Object? json) {
    final errors = <String>[];
    if (json is! Map) throw ManifestException(["manifest is not a JSON object"]);

    String str(String key, {bool required = true, int max = 200}) {
      final value = json[key];
      if (value == null && !required) return "";
      if (value is! String || (required && value.trim().isEmpty)) {
        errors.add("'$key' must be a non-empty string");
        return "";
      }
      if (value.length > max) errors.add("'$key' is longer than $max characters");
      return value.trim();
    }

    if (json["manifestVersion"] != pluginManifestVersion) {
      errors.add("'manifestVersion' must be $pluginManifestVersion");
    }
    final id = str("id", max: 128);
    if (id.isNotEmpty && (!_idPattern.hasMatch(id) || !id.contains("."))) {
      errors.add("'id' must be a lowercase reverse domain like org.example.my-plugin");
    }
    final name = str("name", max: 80);
    final version = str("version", max: 40);
    if (version.isNotEmpty && !_versionPattern.hasMatch(version)) errors.add("'version' must be semver (1.2.3)");
    final author = str("author", max: 120);
    final description = str("description", required: false, max: 1000);
    final homepage = str("homepage", required: false, max: 500);
    if (homepage.isNotEmpty) {
      final uri = Uri.tryParse(homepage);
      if (uri == null || uri.scheme != "https") errors.add("'homepage' must be an https URL");
    }
    final minAppVersion = str("minAppVersion", max: 40);
    if (minAppVersion.isNotEmpty && !_versionPattern.hasMatch(minAppVersion)) {
      errors.add("'minAppVersion' must be semver (1.2.3)");
    }
    final runtime = PluginRuntimeKind.parse(json["runtime"]);
    if (runtime == null)
      errors.add("'runtime' must be one of ${PluginRuntimeKind.values.map((r) => r.name).join(", ")}");
    final entry = str("entry", max: 200);
    if (entry.isNotEmpty && (!_entryPattern.hasMatch(entry) || entry.split("/").contains(".."))) {
      errors.add("'entry' must be a relative path inside the package");
    }
    if (runtime == PluginRuntimeKind.wasm && entry.isNotEmpty && !entry.endsWith(".wasm")) {
      errors.add("a wasm plugin's 'entry' must be a .wasm file");
    }
    if (runtime == PluginRuntimeKind.declarative && entry.isNotEmpty && !entry.endsWith(".json")) {
      errors.add("a declarative plugin's 'entry' must be a .json file");
    }

    final permissions = <PluginPermission>[];
    final rawPermissions = json["permissions"] ?? const <Object?>[];
    if (rawPermissions is! List) {
      errors.add("'permissions' must be a list");
    } else {
      final seen = <String>{};
      for (final raw in rawPermissions) {
        final (permission, error) = PluginPermission.parse(raw);
        if (error != null) errors.add(error);
        if (permission == null) continue;
        if (!seen.add(permission.type)) {
          errors.add("permission '${permission.type}' is declared twice");
          continue;
        }
        permissions.add(permission);
      }
    }

    final extensions = <PluginExtension>[];
    final rawExtensions = json["extensions"];
    if (rawExtensions is! List || rawExtensions.isEmpty) {
      errors.add("'extensions' must list at least one extension point");
    } else {
      final commandIds = <String>{};
      for (final raw in rawExtensions) {
        if (raw is! Map) {
          errors.add("an extension is not an object");
          continue;
        }
        final point = ExtensionPoint.parse(raw["point"]);
        if (point == null) {
          errors.add("unknown extension point '${raw["point"]}'");
          continue;
        }
        final extId = raw["id"];
        final title = raw["title"];
        if (title != null && (title is! String || title.trim().isEmpty || title.length > 60)) {
          errors.add("extension title must be a short non-empty string");
        }
        final targets = <CommandTarget>[];
        if (point == ExtensionPoint.command) {
          if (extId is! String || !_idPattern.hasMatch(extId) || !commandIds.add(extId)) {
            errors.add("each command needs a unique lowercase 'id'");
          }
          if (title is! String) errors.add("command '$extId' needs a 'title'");
          final rawTargets = raw["targets"];
          if (rawTargets is! List || rawTargets.isEmpty) {
            errors.add("command '$extId' needs 'targets' (track, album, artist)");
          } else {
            for (final t in rawTargets) {
              final target = CommandTarget.parse(t);
              if (target == null) {
                errors.add("unknown command target '$t'");
              } else {
                targets.add(target);
              }
            }
          }
        } else if (extensions.any((e) => e.point == point)) {
          errors.add("extension point '${point.wireName}' is declared twice");
        }
        extensions.add(
          PluginExtension(
            point: point,
            id: extId is String ? extId : null,
            title: title is String ? title.trim() : null,
            targets: targets,
          ),
        );
      }
    }

    // Providers that only make sense with the network say so up front rather than failing on first use.
    final needsNetwork = extensions.any((e) => e.point != ExtensionPoint.command);
    if (needsNetwork && !permissions.any((p) => p is NetworkPermission) && runtime == PluginRuntimeKind.declarative) {
      errors.add("a declarative provider needs a network permission");
    }

    if (errors.isNotEmpty) throw ManifestException(errors);
    return PluginManifest._(
      id: id,
      name: name,
      version: version,
      author: author,
      description: description,
      homepage: homepage.isEmpty ? null : homepage,
      minAppVersion: minAppVersion,
      runtime: runtime!,
      entry: entry,
      permissions: List.unmodifiable(permissions),
      extensions: List.unmodifiable(extensions),
    );
  }

  Map<String, Object?> toJson() => {
    "manifestVersion": pluginManifestVersion,
    "id": id,
    "name": name,
    "version": version,
    "author": author,
    if (description.isNotEmpty) "description": description,
    "homepage": ?homepage,
    "minAppVersion": minAppVersion,
    "runtime": runtime.name,
    "entry": entry,
    "permissions": [for (final p in permissions) p.toJson()],
    "extensions": [for (final e in extensions) e.toJson()],
  };

  /// Permissions this manifest declares that [granted] does not cover. A network permission is covered only when
  /// every host is.
  List<PluginPermission> permissionsBeyond(List<PluginPermission> granted) {
    final extra = <PluginPermission>[];
    for (final permission in permissions) {
      if (permission is NetworkPermission) {
        final grantedHosts = granted.whereType<NetworkPermission>().expand((n) => n.hosts).toSet();
        final missing = permission.hosts.where((h) => !grantedHosts.contains(h)).toList();
        if (missing.isNotEmpty) extra.add(NetworkPermission(missing));
      } else if (!granted.any((g) => g.type == permission.type)) {
        extra.add(permission);
      }
    }
    return extra;
  }
}

/// Compares dotted numeric versions (`0.11.0` < `0.11.2`); a pre-release suffix sorts before its release.
int compareVersions(String a, String b) {
  List<int> core(String v) => v.split(RegExp(r"[-+]")).first.split(".").map((p) => int.tryParse(p) ?? 0).toList();
  final ca = core(a), cb = core(b);
  for (var i = 0; i < 3; i++) {
    final x = i < ca.length ? ca[i] : 0;
    final y = i < cb.length ? cb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  final preA = a.contains("-"), preB = b.contains("-");
  if (preA != preB) return preA ? -1 : 1;
  return 0;
}
