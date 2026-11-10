import 'dart:convert';
import 'dart:io';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/library_shortcut.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/media_source_service.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/hidden_items_service.dart';
import 'package:diapason/services/lyrics/lyrics_offset_service.dart';
import 'package:diapason/services/shortcuts/shortcut_service.dart';
import 'package:diapason/services/smart_playlist_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce/hive.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What a restore did, to tell the user.
class BackupRestoreReport {
  int sourcesAdded = 0;
  int sourcesUpdated = 0;
  int sourcesSkipped = 0;
  int sourcesNeedingSignIn = 0;
  bool settingsRestored = false;
  bool jellyfinSignedIn = false;
  int smartPlaylists = 0;
  int pins = 0;
  int hiddenItems = 0;
  int lyricsOffsets = 0;

  String summary() => [
    if (settingsRestored) "settings and home layout",
    if (sourcesAdded > 0) "$sourcesAdded new source${sourcesAdded == 1 ? "" : "s"}",
    if (sourcesUpdated > 0) "$sourcesUpdated updated source${sourcesUpdated == 1 ? "" : "s"}",
    if (smartPlaylists > 0) "$smartPlaylists smart playlist${smartPlaylists == 1 ? "" : "s"}",
    if (pins > 0) "$pins pin${pins == 1 ? "" : "s"}",
    if (hiddenItems > 0) "$hiddenItems hidden item${hiddenItems == 1 ? "" : "s"}",
    if (lyricsOffsets > 0) "$lyricsOffsets lyrics timing${lyricsOffsets == 1 ? "" : "s"}",
  ].join(", ");
}

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Settings backup and restore: one JSON file with the settings (including the home layout), media sources, the
/// Jellyfin sign-in, smart playlists, pins, hidden items and lyrics timings.
///
/// Settings are stored by Hive in its own binary format, so the backup carries a Hive box file holding just the
/// settings object (base64). A restore reads it back through a temporary box, then keeps what only makes sense on
/// this device: download folders, the window size and finished one-time migrations.
class BackupService {
  BackupService();

  static final _log = Logger("BackupService");

  static const format = "diapason-backup";
  static const version = 1;

  static const _settingsBoxName = "FinampSettings";
  static const _settingsKey = "FinampSettings";

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  Future<Uint8List> export({required bool includeSignIns}) async {
    final package = await PackageInfo.fromPlatform();
    final settings = Hive.box<FinampSettings>(_settingsBoxName).get(_settingsKey)!;

    final json = <String, dynamic>{
      "format": format,
      "version": version,
      "createdAt": DateTime.now().toUtc().toIso8601String(),
      "appVersion": package.version,
      "platform": Platform.operatingSystem,
      "includesSignIns": includeSignIns,
      "settings": base64Encode(await encodeSettings(settings, includeSignIns: includeSignIns)),
      "sources": [
        for (final source in _sources)
          if (source.kind != MediaSourceKind.local) _sourceJson(source, includeSignIns: includeSignIns),
      ],
      if (includeSignIns && _jellyfinUser() != null) "jellyfinUser": _jellyfinUser(),
      "smartPlaylists": await _smartPlaylists(),
      "pins": [for (final pin in _pins) _pinJson(pin)],
      "hiddenItems": HiddenItemsService.hiddenIds.toList(),
      "lyricsOffsets": LyricsOffsetService.all(),
    };
    return Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent("  ").convert(json)));
  }

  static String suggestedFileName([DateTime? now]) {
    final d = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, "0");
    return "diapason-backup-${d.year}-${two(d.month)}-${two(d.day)}.json";
  }

  /// Fields holding credentials for third-party services. Left out of a backup made without sign-ins, and never
  /// cleared on restore by a backup that doesn't have them.
  static void _forEachSecret(FinampSettings settings, void Function(String Function() get, void Function(String) set) visit) {
    visit(() => settings.listenBrainzToken, (v) => settings.listenBrainzToken = v);
    visit(() => settings.lastFmApiKey, (v) => settings.lastFmApiKey = v);
    visit(() => settings.lastFmApiSecret, (v) => settings.lastFmApiSecret = v);
    visit(() => settings.lastFmSessionKey, (v) => settings.lastFmSessionKey = v);
    visit(() => settings.uploaderToken, (v) => settings.uploaderToken = v);
  }

  /// A Hive box file holding only [settings], as bytes. The live settings object is never changed.
  @visibleForTesting
  static Future<Uint8List> encodeSettings(FinampSettings settings, {required bool includeSignIns}) async {
    return _withTempBox((box) async {
      final path = box.path!;
      await box.put(_settingsKey, settings);
      await box.close();
      if (!includeSignIns) {
        // Reading back gives a fresh copy, which can lose its secrets without touching the live settings.
        final reopened = await Hive.openBox<FinampSettings>(box.name, path: p.dirname(path));
        final copy = reopened.get(_settingsKey)!;
        _forEachSecret(copy, (_, set) => set(""));
        await reopened.put(_settingsKey, copy);
        await reopened.compact();
        await reopened.close();
      }
      return File(path).readAsBytes();
    });
  }

  @visibleForTesting
  static Future<FinampSettings> decodeSettings(Uint8List bytes) async {
    final dir = await Directory.systemTemp.createTemp("diapason-restore");
    try {
      const name = "diapasonrestore";
      await File(p.join(dir.path, "$name.hive")).writeAsBytes(bytes, flush: true);
      final box = await Hive.openBox<FinampSettings>(name, path: dir.path);
      final settings = box.get(_settingsKey);
      await box.close();
      if (settings == null) throw const BackupFormatException("The backup has no settings in it.");
      return settings;
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<T> _withTempBox<T>(Future<T> Function(Box<FinampSettings> box) body) async {
    final dir = await Directory.systemTemp.createTemp("diapason-backup");
    try {
      final box = await Hive.openBox<FinampSettings>("diapasonbackup", path: dir.path);
      try {
        return await body(box);
      } finally {
        if (Hive.isBoxOpen("diapasonbackup")) await Hive.box<FinampSettings>("diapasonbackup").close();
      }
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Takes everything from [restored] except what belongs to this device, which comes from [current].
  @visibleForTesting
  static FinampSettings mergeForThisDevice(FinampSettings restored, FinampSettings current) {
    restored
      ..downloadLocations = current.downloadLocations
      ..downloadLocationsMap = current.downloadLocationsMap
      ..defaultDownloadLocation = current.defaultDownloadLocation
      ..lastUsedDownloadLocationId = current.lastUsedDownloadLocationId
      ..screenSize = current.screenSize
      ..hasCompletedDownloadsServiceMigration = current.hasCompletedDownloadsServiceMigration
      ..hasCompletedIsarUserMigration = current.hasCompletedIsarUserMigration
      ..hasDownloadedPlaylistInfo = current.hasDownloadedPlaylistInfo
      ..hasCompletedDownloadsFileOwnerMigration = current.hasCompletedDownloadsFileOwnerMigration
      ..hasCompletedThemeModeLocaleMigration = current.hasCompletedThemeModeLocaleMigration;

    // A backup made without sign-ins mustn't sign this device out of anything.
    final currentSecrets = <String>[];
    _forEachSecret(current, (get, _) => currentSecrets.add(get()));
    var i = 0;
    _forEachSecret(restored, (get, set) {
      final mine = currentSecrets[i++];
      if (get().isEmpty && mine.isNotEmpty) set(mine);
    });
    return restored;
  }

  // ---------------------------------------------------------------------------
  // Restore
  // ---------------------------------------------------------------------------

  /// Checks the file and returns its contents. Throws [BackupFormatException] if it isn't a Diapason backup.
  static Map<String, dynamic> parse(Uint8List bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const BackupFormatException("That file isn't a Diapason backup.");
    }
    if (json is! Map<String, dynamic> || json["format"] != format) {
      throw const BackupFormatException("That file isn't a Diapason backup.");
    }
    final fileVersion = json["version"];
    if (fileVersion is! int || fileVersion > version) {
      throw const BackupFormatException("This backup was made by a newer Diapason. Update the app, then try again.");
    }
    return json;
  }

  Future<BackupRestoreReport> restore(Uint8List bytes) async {
    final json = parse(bytes);
    final report = BackupRestoreReport();
    final includesSignIns = json["includesSignIns"] == true;

    if (json["settings"] case final String encoded) {
      final restored = await decodeSettings(base64Decode(encoded));
      final box = Hive.box<FinampSettings>(_settingsBoxName);
      await box.put(_settingsKey, mergeForThisDevice(restored, box.get(_settingsKey)!));
      report.settingsRestored = true;
    }

    if (json["jellyfinUser"] case final Map<String, dynamic> user) {
      report.jellyfinSignedIn = await _restoreJellyfinUser(user);
    }

    for (final raw in (json["sources"] as List?)?.whereType<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[]) {
      try {
        await _restoreSource(MediaSourceConfig.fromTvOSStorageJson(raw), includesSignIns: includesSignIns, report: report);
      } catch (e) {
        _log.warning("Skipped a source from the backup: $e");
        report.sourcesSkipped++;
      }
    }

    if (json["smartPlaylists"] case final Map<String, dynamic> playlists) {
      final box = Hive.isBoxOpen("SmartPlaylists")
          ? Hive.box<String>("SmartPlaylists")
          : await Hive.openBox<String>("SmartPlaylists");
      await box.putAll({for (final e in playlists.entries) if (e.value is String) e.key: e.value as String});
      report.smartPlaylists = playlists.length;
    }

    if (json["pins"] case final List<dynamic> pins) {
      report.pins = await _restorePins(pins.whereType<Map<String, dynamic>>().toList());
    }

    if (json["hiddenItems"] case final List<dynamic> hidden) {
      for (final id in hidden.whereType<String>()) {
        await HiddenItemsService.hide(BaseItemId(id));
      }
      report.hiddenItems = hidden.length;
    }

    if (json["lyricsOffsets"] case final Map<String, dynamic> offsets) {
      final valid = {for (final e in offsets.entries) if (e.value is int) e.key: e.value as int};
      await LyricsOffsetService.restore(valid);
      report.lyricsOffsets = valid.length;
    }

    _log.info("Restored a backup: ${report.summary()}");
    return report;
  }

  // ---------------------------------------------------------------------------
  // Pieces
  // ---------------------------------------------------------------------------

  List<MediaSourceConfig> get _sources =>
      GetIt.instance.isRegistered<MediaSourceService>() ? GetIt.instance<MediaSourceService>().sources : const [];

  static Map<String, dynamic> _sourceJson(MediaSourceConfig source, {required bool includeSignIns}) {
    final json = source.toTvOSStorageJson();
    if (!includeSignIns) {
      json
        ..["accessToken"] = ""
        ..["password"] = "";
    }
    return json;
  }

  static String _address(String? address) {
    var a = (address ?? "").trim().toLowerCase();
    while (a.endsWith("/")) {
      a = a.substring(0, a.length - 1);
    }
    return a;
  }

  Future<void> _restoreSource(
    MediaSourceConfig incoming, {
    required bool includesSignIns,
    required BackupRestoreReport report,
  }) async {
    final service = GetIt.instance<MediaSourceService>();
    if (incoming.kind == MediaSourceKind.local || incoming.kind == MediaSourceKind.youtube) {
      // Folders on another device don't exist here; YouTube needs no stored source.
      report.sourcesSkipped++;
      return;
    }

    final existing = service.sources.where((s) => s.sourceId == incoming.sourceId).firstOrNull;
    if (existing != null) {
      // Keep this device's sign-in when the backup has none.
      if (incoming.accessToken.isEmpty) incoming.accessToken = existing.accessToken;
      if (incoming.password.isEmpty) incoming.password = existing.password;
      await service.updateSource(incoming);
      report.sourcesUpdated++;
      return;
    }

    final sameAccount = service.sources.any(
      (s) =>
          s.kind == incoming.kind &&
          _address(s.publicAddress) == _address(incoming.publicAddress) &&
          s.username.toLowerCase() == incoming.username.toLowerCase() &&
          s.userId == incoming.userId,
    );
    if (sameAccount) {
      report.sourcesSkipped++;
      return;
    }

    await service.addSource(incoming);
    report.sourcesAdded++;
    if (!includesSignIns || (incoming.accessToken.isEmpty && incoming.password.isEmpty)) {
      report.sourcesNeedingSignIn++;
    }
  }

  static Map<String, dynamic>? _jellyfinUser() {
    if (!GetIt.instance.isRegistered<FinampUserHelper>()) return null;
    final user = GetIt.instance<FinampUserHelper>().currentUser;
    if (user == null) return null;
    return {
      "id": user.id,
      "publicAddress": user.publicAddress,
      "localAddress": user.localAddress,
      "preferLocalNetwork": user.preferLocalNetwork,
      "isLocal": user.isLocal,
      "accessToken": user.accessToken,
      "serverId": user.serverId,
      "currentViewId": user.currentViewId?.raw,
      "views": [for (final view in user.views.values) view.toJson(setOffline: false)],
    };
  }

  Future<bool> _restoreJellyfinUser(Map<String, dynamic> json) async {
    final helper = GetIt.instance<FinampUserHelper>();
    // Never replace an account this device is already signed in to.
    if (helper.currentUser != null) return false;
    final token = json["accessToken"] as String? ?? "";
    if (token.isEmpty) return false;

    final views = <BaseItemId, BaseItemDto>{};
    for (final raw in (json["views"] as List?)?.whereType<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[]) {
      final view = BaseItemDto.fromJson(raw);
      views[view.id] = view;
    }
    final currentViewId = json["currentViewId"] as String?;
    await helper.saveUser(
      FinampUser(
        id: json["id"] as String,
        publicAddress: json["publicAddress"] as String? ?? "",
        localAddress: json["localAddress"] as String? ?? "",
        preferLocalNetwork: json["preferLocalNetwork"] as bool? ?? false,
        isLocal: json["isLocal"] as bool? ?? false,
        accessToken: token,
        serverId: json["serverId"] as String? ?? "",
        currentViewId: currentViewId == null ? null : BaseItemId(currentViewId),
        views: views,
      ),
    );
    return true;
  }

  static Future<Map<String, String>> _smartPlaylists() async {
    // Make sure the box exists even if smart playlists were never opened this session.
    await SmartPlaylistService.instance.list();
    final box = Hive.box<String>("SmartPlaylists");
    return {for (final key in box.keys) "$key": box.get(key)!};
  }

  static List<PinnedItem> get _pins =>
      GetIt.instance.isRegistered<Isar>() && GetIt.instance.isRegistered<ShortcutService>()
      ? GetIt.instance<ShortcutService>().pins
      : const [];

  static Map<String, dynamic> _pinJson(PinnedItem pin) => {
    "itemId": pin.itemId,
    "name": pin.name,
    "subtitle": pin.subtitle,
    "type": pin.type,
    "pinnedAt": pin.pinnedAt.toUtc().toIso8601String(),
    "sortIndex": pin.sortIndex,
  };

  Future<int> _restorePins(List<Map<String, dynamic>> pins) async {
    if (!GetIt.instance.isRegistered<Isar>() || !GetIt.instance.isRegistered<ShortcutService>()) return 0;
    final restored = [
      for (final raw in pins)
        if (raw["itemId"] case final String itemId)
          PinnedItem(
            itemId: itemId,
            name: raw["name"] as String? ?? "Unknown",
            subtitle: raw["subtitle"] as String?,
            type: raw["type"] as String? ?? "MusicAlbum",
            pinnedAt: DateTime.tryParse(raw["pinnedAt"] as String? ?? "")?.toLocal() ?? DateTime.now(),
            sortIndex: (raw["sortIndex"] as num?)?.toInt() ?? 0,
          ),
    ];
    return GetIt.instance<ShortcutService>().restorePins(restored);
  }
}

/// Where a backup goes while it's shared from a phone (the share sheet needs a real file).
Future<File> writeBackupToTemp(Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, BackupService.suggestedFileName()));
  await file.writeAsBytes(bytes, flush: true);
  return file;
}
