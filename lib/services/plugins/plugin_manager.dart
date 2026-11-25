import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/plugins/extension_points.dart';
import 'package:diapason/services/plugins/plugin_catalog.dart';
import 'package:diapason/services/plugins/plugin_extensions.dart';
import 'package:diapason/services/plugins/plugin_host.dart';
import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:diapason/services/plugins/plugin_package.dart';
import 'package:diapason/services/plugins/plugin_runtime.dart';
import 'package:diapason/services/plugins/wasm_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Where a plugin was installed from, so updates know where to look.
class PluginOrigin {
  const PluginOrigin({this.catalogUrl, this.packageUrl});

  /// Null for a package installed from a file.
  final String? catalogUrl;
  final String? packageUrl;

  bool get isFile => catalogUrl == null && packageUrl == null;

  Map<String, Object?> toJson() => {"catalogUrl": ?catalogUrl, "packageUrl": ?packageUrl};

  static PluginOrigin fromJson(Object? json) => json is Map
      ? PluginOrigin(catalogUrl: json["catalogUrl"] as String?, packageUrl: json["packageUrl"] as String?)
      : const PluginOrigin();
}

/// What is remembered about an installed plugin. Stored as JSON in the `Plugins` Hive box.
class PluginRecord {
  PluginRecord({
    required this.id,
    required this.version,
    required this.sha256,
    required this.enabled,
    required this.granted,
    required this.origin,
    required this.installedAt,
  });

  final String id;
  final String version;
  final String sha256;
  final bool enabled;

  /// The permissions the user approved. Only these are honoured.
  final List<PluginPermission> granted;
  final PluginOrigin origin;
  final DateTime installedAt;

  PluginRecord copyWith({bool? enabled, List<PluginPermission>? granted}) => PluginRecord(
    id: id,
    version: version,
    sha256: sha256,
    enabled: enabled ?? this.enabled,
    granted: granted ?? this.granted,
    origin: origin,
    installedAt: installedAt,
  );

  String encode() => jsonEncode({
    "id": id,
    "version": version,
    "sha256": sha256,
    "enabled": enabled,
    "granted": [for (final g in granted) g.toJson()],
    "origin": origin.toJson(),
    "installedAt": installedAt.toIso8601String(),
  });

  static PluginRecord? decode(String source) {
    try {
      final json = jsonDecode(source) as Map;
      return PluginRecord(
        id: json["id"] as String,
        version: json["version"] as String,
        sha256: json["sha256"] as String,
        enabled: json["enabled"] == true,
        granted: [
          for (final raw in (json["granted"] as List? ?? const []))
            if (PluginPermission.parse(raw).$1 case final permission?) permission,
        ],
        origin: PluginOrigin.fromJson(json["origin"]),
        installedAt: DateTime.tryParse(json["installedAt"] as String? ?? "") ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}

enum PluginStatus {
  /// Enabled and loaded; its extensions are registered.
  running,
  disabled,

  /// Enabled, but the installed version declares permissions the user has not approved yet.
  needsApproval,

  /// Enabled, but it could not be loaded or it failed too often.
  failed,
}

class InstalledPlugin {
  const InstalledPlugin({required this.manifest, required this.record, required this.status, this.problem});

  final PluginManifest manifest;
  final PluginRecord record;
  final PluginStatus status;
  final String? problem;

  /// Declared but not approved.
  List<PluginPermission> get unapproved => manifest.permissionsBeyond(record.granted);
}

/// A package that was read and checked, waiting for the user to approve its permissions.
class PendingInstall {
  const PendingInstall({required this.package, required this.origin, this.existing});

  final PluginPackage package;
  final PluginOrigin origin;

  /// The installed version this would replace.
  final InstalledPlugin? existing;

  PluginManifest get manifest => package.manifest;

  bool get isUpdate => existing != null;

  /// What the user must approve: everything for a new plugin, only what is new for an update.
  List<PluginPermission> get permissionsToApprove =>
      existing == null ? manifest.permissions : manifest.permissionsBeyond(existing!.record.granted);
}

class PluginInstallException implements Exception {
  PluginInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An available update from a catalog.
class PluginUpdate {
  const PluginUpdate(this.installed, this.entry);

  final InstalledPlugin installed;
  final CatalogEntry entry;
}

/// Installs, loads and unloads plugins, and keeps [registry] in step with what is enabled.
class PluginManager extends ChangeNotifier {
  PluginManager({
    required this.appVersion,
    required Directory root,
    required this.services,
    ExtensionRegistry? registry,
    http.Client? httpClient,
    Box<String>? box,
  }) : registry = registry ?? ExtensionRegistry(),
       _root = root,
       _http = httpClient ?? http.Client(),
       _box = box;

  static final _log = Logger("PluginManager");

  static const boxName = "Plugins";
  static const _catalogsKey = "catalogs";
  static const _recordPrefix = "plugin:";

  final String appVersion;
  final PluginHostServices services;
  final ExtensionRegistry registry;
  final Directory _root;
  final http.Client _http;
  Box<String>? _box;

  final _installed = <String, InstalledPlugin>{};
  final _runtimes = <String, PluginRuntime>{};
  final _logs = <String, PluginLog>{};

  Directory get _packagesDir => Directory(p.join(_root.path, "packages"));
  Directory get _dataDir => Directory(p.join(_root.path, "data"));

  List<InstalledPlugin> get installed =>
      _installed.values.toList()..sort((a, b) => a.manifest.name.compareTo(b.manifest.name));

  InstalledPlugin? operator [](String id) => _installed[id];

  PluginLog logFor(String id) => _logs.putIfAbsent(id, () => PluginLog(id));

  List<String> get catalogUrls {
    final raw = _box?.get(_catalogsKey);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setCatalogUrls(List<String> urls) async {
    await _box?.put(_catalogsKey, jsonEncode(urls.toSet().toList()));
    notifyListeners();
  }

  /// Opens the box and loads every enabled plugin. Plugins that fail to load are reported, never fatal.
  Future<void> init() async {
    _box ??= await Hive.openBox<String>(boxName);
    for (final key in _box!.keys.whereType<String>().where((k) => k.startsWith(_recordPrefix))) {
      final record = PluginRecord.decode(_box!.get(key)!);
      if (record == null) continue;
      try {
        final manifest = await _readInstalledManifest(record.id);
        _installed[record.id] = InstalledPlugin(manifest: manifest, record: record, status: PluginStatus.disabled);
        if (record.enabled) await _load(record.id);
      } catch (e) {
        _log.warning("Plugin ${record.id} is installed but unreadable: $e");
        logFor(record.id).add(PluginLogLevel.error, "Could not read the installed package: $e");
      }
    }
    notifyListeners();
  }

  Future<PluginManifest> _readInstalledManifest(String id) async {
    final file = File(p.join(_packagesDir.path, id, "manifest.json"));
    return PluginManifest.parseString(await file.readAsString());
  }

  // ---- Installing -----------------------------------------------------------------------------------------------

  /// Reads a package and checks everything (manifest, entry, code) without installing it.
  Future<PendingInstall> prepare(
    Uint8List zip, {
    PluginOrigin origin = const PluginOrigin(),
    String? expectedSha256,
  }) async {
    final PluginPackage package;
    try {
      package = PluginPackage.read(zip, expectedSha256: expectedSha256, appVersion: appVersion);
    } on PluginPackageException catch (e) {
      throw PluginInstallException(e.message);
    } on ManifestException catch (e) {
      throw PluginInstallException(e.errors.join("\n"));
    }
    await _checkCode(package.manifest, package.entryBytes);
    return PendingInstall(package: package, origin: origin, existing: _installed[package.manifest.id]);
  }

  Future<void> _checkCode(PluginManifest manifest, Uint8List entry) async {
    switch (manifest.runtime) {
      case PluginRuntimeKind.declarative:
        try {
          DeclarativeRuntime.validate(manifest, utf8.decode(entry));
        } on ManifestException catch (e) {
          throw PluginInstallException(e.errors.join("\n"));
        } on FormatException {
          throw PluginInstallException("${manifest.entry} is not UTF-8");
        }
      case PluginRuntimeKind.wasm:
        try {
          await WasmRuntime.validate(entry);
        } on PluginCallException catch (e) {
          throw PluginInstallException(e.message);
        } catch (e) {
          throw PluginInstallException("plugin.wasm cannot be loaded: $e");
        }
    }
  }

  /// Installs (or updates) [pending] and enables it with [granted], which must cover every permission it declares.
  /// A plugin is never enabled with less than it declares: it would fail in confusing ways instead.
  Future<void> install(PendingInstall pending, {required List<PluginPermission> granted}) async {
    final manifest = pending.manifest;
    if (manifest.permissionsBeyond(granted).isNotEmpty) {
      throw PluginInstallException("Every permission the plugin declares must be approved to enable it.");
    }
    await _unload(manifest.id);
    final dir = Directory(p.join(_packagesDir.path, manifest.id));
    final staging = Directory("${dir.path}.new");
    if (await staging.exists()) await staging.delete(recursive: true);
    for (final entry in pending.package.files.entries) {
      final file = File(p.join(staging.path, entry.key));
      // normalizeEntryName already refused anything that could leave the folder; check again on the joined path.
      if (!p.isWithin(staging.path, file.path)) throw PluginInstallException("unsafe path ${entry.key}");
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value);
    }
    if (await dir.exists()) await dir.delete(recursive: true);
    await staging.rename(dir.path);

    final record = PluginRecord(
      id: manifest.id,
      version: manifest.version,
      sha256: pending.package.sha256,
      enabled: true,
      // Keep only what is still declared: an update that drops a permission drops the grant too.
      granted: _grantsFor(manifest, granted),
      origin: pending.origin,
      installedAt: DateTime.now(),
    );
    await _box?.put("$_recordPrefix${manifest.id}", record.encode());
    _installed[manifest.id] = InstalledPlugin(manifest: manifest, record: record, status: PluginStatus.disabled);
    logFor(manifest.id).add(
      PluginLogLevel.info,
      "${pending.isUpdate ? "Updated to" : "Installed"} ${manifest.version} (${pending.package.sha256.substring(0, 12)})",
    );
    await _load(manifest.id);
    notifyListeners();
  }

  static List<PluginPermission> _grantsFor(PluginManifest manifest, List<PluginPermission> granted) => [
    for (final permission in manifest.permissions)
      if (permission is NetworkPermission)
        NetworkPermission([
          for (final host in permission.hosts)
            if (granted.whereType<NetworkPermission>().any((g) => g.hosts.contains(host))) host,
        ])
      else if (granted.any((g) => g.type == permission.type))
        permission,
  ].where((p) => p is! NetworkPermission || p.hosts.isNotEmpty).toList();

  Future<void> uninstall(String id) async {
    await _unload(id);
    _installed.remove(id);
    await _box?.delete("$_recordPrefix$id");
    for (final dir in [Directory(p.join(_packagesDir.path, id)), Directory(p.join(_dataDir.path, id))]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    _logs.remove(id);
    notifyListeners();
  }

  /// Enabling a plugin whose permissions are not all approved needs [approve] (the user saw them).
  Future<void> setEnabled(String id, bool enabled, {bool approve = false}) async {
    final plugin = _installed[id];
    if (plugin == null) return;
    var record = plugin.record.copyWith(enabled: enabled);
    if (enabled && approve) record = record.copyWith(granted: plugin.manifest.permissions);
    await _box?.put("$_recordPrefix$id", record.encode());
    _installed[id] = InstalledPlugin(manifest: plugin.manifest, record: record, status: PluginStatus.disabled);
    if (enabled) {
      await _load(id);
    } else {
      await _unload(id);
      logFor(id).add(PluginLogLevel.info, "Disabled");
    }
    notifyListeners();
  }

  /// Forgets everything the plugin stored.
  Future<void> clearData(String id) async {
    final dir = Directory(p.join(_dataDir.path, id));
    if (await dir.exists()) await dir.delete(recursive: true);
    if (_installed[id]?.record.enabled ?? false) await _load(id);
    logFor(id).add(PluginLogLevel.info, "Stored data cleared");
    notifyListeners();
  }

  // ---- Loading ----------------------------------------------------------------------------------------------------

  Future<void> _load(String id) async {
    await _unload(id);
    final plugin = _installed[id];
    if (plugin == null) return;
    final log = logFor(id);
    if (plugin.unapproved.isNotEmpty) {
      _installed[id] = InstalledPlugin(
        manifest: plugin.manifest,
        record: plugin.record,
        status: PluginStatus.needsApproval,
      );
      log.add(PluginLogLevel.warning, "Not started: it declares permissions that were not approved");
      return;
    }
    try {
      final manifest = plugin.manifest;
      final entry = await File(p.join(_packagesDir.path, id, manifest.entry)).readAsBytes();
      final bridge = PluginHostBridge(
        pluginId: id,
        granted: plugin.record.granted,
        log: log,
        storage: FilePluginStorage(File(p.join(_dataDir.path, id, "storage.json"))),
        services: services,
        httpClient: _http,
      );
      final PluginRuntime runtime = switch (manifest.runtime) {
        PluginRuntimeKind.declarative => DeclarativeRuntime.load(manifest, utf8.decode(entry), bridge),
        PluginRuntimeKind.wasm => WasmRuntime(module: entry, bridge: bridge),
      };
      _runtimes[id] = runtime;
      for (final extension in extensionsFor(manifest, runtime, bridge)) {
        registry.register(extension);
      }
      _installed[id] = InstalledPlugin(manifest: manifest, record: plugin.record, status: PluginStatus.running);
      log.add(PluginLogLevel.info, "Started ${manifest.version} (${manifest.runtime.name})");
    } catch (e) {
      _installed[id] = InstalledPlugin(
        manifest: plugin.manifest,
        record: plugin.record,
        status: PluginStatus.failed,
        problem: "$e",
      );
      log.add(PluginLogLevel.error, "Could not start: $e");
    }
  }

  Future<void> _unload(String id) async {
    registry.unregisterOwner(id);
    final runtime = _runtimes.remove(id);
    if (runtime != null) await runtime.dispose();
  }

  /// A suspended WASM runtime shows as failed; call after a lookup to refresh statuses.
  void refreshStatuses() {
    var changed = false;
    for (final entry in _runtimes.entries) {
      final runtime = entry.value;
      if (runtime is WasmRuntime && runtime.suspendedReason != null) {
        final plugin = _installed[entry.key]!;
        if (plugin.status != PluginStatus.failed) {
          _installed[entry.key] = InstalledPlugin(
            manifest: plugin.manifest,
            record: plugin.record,
            status: PluginStatus.failed,
            problem: runtime.suspendedReason,
          );
          changed = true;
        }
      }
    }
    if (changed) notifyListeners();
  }

  // ---- Catalogs and downloads ---------------------------------------------------------------------------------------

  Future<List<int>> _download(Uri url, int maxBytes) async {
    if (services.isOffline()) throw PluginInstallException("Diapason is offline.");
    final request = http.Request("GET", url)..headers["User-Agent"] = PluginHostBridge.userAgent;
    final response = await _http.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw PluginInstallException("${url.host} answered HTTP ${response.statusCode}");
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
      out.add(chunk);
      if (out.length > maxBytes) throw PluginInstallException("download is larger than ${maxBytes ~/ 1024} KiB");
    }
    return out.takeBytes();
  }

  Future<PluginCatalog> fetchCatalog(String url) async {
    final normalized = PluginCatalog.normalizeUrl(url);
    if (normalized == null) throw PluginInstallException("Not a valid catalog URL.");
    final bytes = await _download(Uri.parse(normalized), PluginCatalog.maxBytes);
    try {
      return PluginCatalog.parse(normalized, bytes, appVersion: appVersion);
    } on CatalogException catch (e) {
      throw PluginInstallException(e.message);
    }
  }

  /// Downloads a catalog entry's package and checks it against the catalog's checksum.
  Future<PendingInstall> prepareFromCatalog(CatalogEntry entry) async {
    if (!entry.installable) throw PluginInstallException(entry.problem!);
    final bytes = await _download(entry.packageUrl!, PluginPackage.maxPackageBytes);
    final pending = await prepare(
      Uint8List.fromList(bytes),
      origin: PluginOrigin(catalogUrl: entry.catalogUrl, packageUrl: entry.packageUrl.toString()),
      expectedSha256: entry.sha256,
    );
    if (pending.manifest.id != entry.id) {
      throw PluginInstallException("The package is '${pending.manifest.id}', the catalog said '${entry.id}'.");
    }
    return pending;
  }

  /// Installed plugins that a newer version of is listed in [catalogs].
  List<PluginUpdate> updatesIn(Iterable<PluginCatalog> catalogs) {
    final updates = <PluginUpdate>[];
    for (final plugin in _installed.values) {
      CatalogEntry? best;
      for (final catalog in catalogs) {
        for (final entry in catalog.entries) {
          if (entry.id != plugin.manifest.id || !entry.installable) continue;
          // Updates come only from the catalog the plugin was installed from, when it came from one.
          final from = plugin.record.origin.catalogUrl;
          if (from != null && from != entry.catalogUrl) continue;
          if (compareVersions(entry.version, plugin.manifest.version) <= 0) continue;
          if (best == null || compareVersions(entry.version, best.version) > 0) best = entry;
        }
      }
      if (best != null) updates.add(PluginUpdate(plugin, best));
    }
    return updates;
  }

  @override
  void dispose() {
    for (final id in _runtimes.keys.toList()) {
      unawaited(_unload(id));
    }
    super.dispose();
  }
}
