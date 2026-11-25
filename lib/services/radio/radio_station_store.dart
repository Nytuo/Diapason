import 'dart:convert';

import 'package:diapason/models/radio_station.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';

/// The user's own radio stations (favourites from the directory and stations
/// added by URL) plus the few last played, kept on this device.
///
/// A Hive box of JSON strings, so it works on every platform, tvOS included.
class RadioStationStore {
  static const boxName = "RadioStations";
  static final _log = Logger("RadioStationStore");

  static const _savedPrefix = "saved:";
  static const _recentPrefix = "recent:";
  static const _maxRecent = 20;

  static Box<String>? get _box => Hive.isBoxOpen(boxName) ? Hive.box<String>(boxName) : null;

  static Future<void> open() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox<String>(boxName);
  }

  static List<({RadioStation station, int at})> _entries(String prefix) {
    final box = _box;
    if (box == null) return const [];
    final result = <({RadioStation station, int at})>[];
    for (final key in box.keys.whereType<String>().where((k) => k.startsWith(prefix))) {
      try {
        final json = jsonDecode(box.get(key)!) as Map<String, dynamic>;
        result.add((
          station: RadioStation.fromJson((json["station"] as Map).cast<String, dynamic>()),
          at: json["at"] as int? ?? 0,
        ));
      } catch (e) {
        _log.warning("Dropping unreadable radio station entry $key: $e");
      }
    }
    return result;
  }

  /// Saved stations, oldest first (the order they were added).
  static List<RadioStation> get saved =>
      (_entries(_savedPrefix)..sort((a, b) => a.at.compareTo(b.at))).map((e) => e.station).toList();

  /// Recently played stations, most recent first.
  static List<RadioStation> get recent =>
      (_entries(_recentPrefix)..sort((a, b) => b.at.compareTo(a.at))).map((e) => e.station).toList();

  static bool isSaved(String id) => _box?.containsKey("$_savedPrefix$id") ?? false;

  static RadioStation? find(String id) {
    final box = _box;
    if (box == null) return null;
    for (final key in ["$_savedPrefix$id", "$_recentPrefix$id"]) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        return RadioStation.fromJson((json["station"] as Map).cast<String, dynamic>());
      } catch (_) {}
    }
    return null;
  }

  static Future<void> _put(String prefix, RadioStation station, {int? at}) async {
    final box = _box;
    if (box == null) return;
    final existing = box.get("$prefix${station.id}");
    var keepAt = at;
    if (keepAt == null && existing != null) {
      try {
        keepAt = (jsonDecode(existing) as Map<String, dynamic>)["at"] as int?;
      } catch (_) {}
    }
    await box.put(
      "$prefix${station.id}",
      jsonEncode({"station": station.toJson(), "at": keepAt ?? DateTime.now().millisecondsSinceEpoch}),
    );
  }

  /// Saves (or updates, keeping its position) a station.
  static Future<void> save(RadioStation station) => _put(_savedPrefix, station);

  static Future<void> remove(String id) async {
    await _box?.delete("$_savedPrefix$id");
  }

  /// Creates a custom station from a stream or playlist URL.
  static Future<RadioStation> addCustom({
    required String name,
    required String streamUrl,
    String? faviconUrl,
    String? homepage,
    List<String> tags = const [],
  }) async {
    final station = RadioStation(
      id: "custom-${const Uuid().v4()}",
      name: name.trim(),
      streamUrl: streamUrl.trim(),
      faviconUrl: (faviconUrl ?? "").trim().isEmpty ? null : faviconUrl!.trim(),
      homepage: (homepage ?? "").trim().isEmpty ? null : homepage!.trim(),
      tags: tags,
      isCustom: true,
    );
    await save(station);
    return station;
  }

  /// Remembers a played station so a restored queue can find it again and the
  /// radio screen can list it under "Recently played".
  static Future<void> markPlayed(RadioStation station) async {
    await _put(_recentPrefix, station, at: DateTime.now().millisecondsSinceEpoch);
    final recents = _entries(_recentPrefix)..sort((a, b) => b.at.compareTo(a.at));
    for (final old in recents.skip(_maxRecent)) {
      await _box?.delete("$_recentPrefix${old.station.id}");
    }
  }

  static Future<void> clearRecent() async {
    final box = _box;
    if (box == null) return;
    await box.deleteAll(box.keys.whereType<String>().where((k) => k.startsWith(_recentPrefix)).toList());
  }

  /// Fires whenever the stored stations change.
  static Stream<void> get changes => _box?.watch().map((_) {}) ?? const Stream.empty();

  /// URL validation for the add/edit dialog.
  static bool isValidStreamUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && (uri.isScheme("http") || uri.isScheme("https")) && uri.host.isNotEmpty;
  }
}

final savedRadioStationsProvider = StreamProvider<List<RadioStation>>(
  (ref) => RadioStationStore.changes.map((_) => RadioStationStore.saved).startWith(RadioStationStore.saved),
);

final recentRadioStationsProvider = StreamProvider<List<RadioStation>>(
  (ref) => RadioStationStore.changes.map((_) => RadioStationStore.recent).startWith(RadioStationStore.recent),
);
