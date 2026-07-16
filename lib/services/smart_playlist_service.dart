import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/smart_playlist.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce/hive.dart';

class SmartPlaylistService {
  SmartPlaylistService._();
  static final SmartPlaylistService instance = SmartPlaylistService._();

  static const _boxName = "SmartPlaylists";
  Box<String>? _box;

  Future<Box<String>> _openBox() async {
    if (_box != null && _box!.isOpen) return _box!;
    _box = Hive.isBoxOpen(_boxName) ? Hive.box<String>(_boxName) : await Hive.openBox<String>(_boxName);
    return _box!;
  }

  Future<List<SmartPlaylist>> list() async {
    final box = await _openBox();
    return box.values.map(SmartPlaylist.decode).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> save(SmartPlaylist playlist) async {
    final box = await _openBox();
    await box.put(playlist.id, playlist.encode());
  }

  Future<void> delete(String id) async {
    final box = await _openBox();
    await box.delete(id);
  }

  Future<SmartPlaylist?> get(String id) async {
    final box = await _openBox();
    final raw = box.get(id);
    return raw == null ? null : SmartPlaylist.decode(raw);
  }

  Future<List<BaseItemDto>> resolve(SmartPlaylist playlist) async {
    final backend = GetIt.instance<AggregateBackend>();
    final tracks = await backend.getItems(includeItemTypes: "Audio", limit: 10000);

    final matched = tracks.where((track) {
      if (playlist.rules.isEmpty) return true;
      final results = playlist.rules.map((rule) => _matches(track, rule));
      return playlist.matchAll ? results.every((r) => r) : results.any((r) => r);
    }).toList();

    _sort(matched, playlist);
    if (playlist.limit != null && matched.length > playlist.limit!) {
      return matched.sublist(0, playlist.limit!);
    }
    return matched;
  }

  bool _matches(BaseItemDto track, SmartRule rule) {
    switch (rule.field) {
      case SmartField.favorite:
        final fav = track.userData?.isFavorite ?? false;
        final want = rule.value.toLowerCase() == "true" || rule.value.toLowerCase() == "yes";
        return rule.op == SmartOp.notEquals ? fav != want : fav == want;
      case SmartField.year:
        return _compareNum(track.productionYear, rule);
      case SmartField.playCount:
        return _compareNum(track.userData?.playCount, rule);
      case SmartField.title:
        return _compareText(track.name, rule);
      case SmartField.artist:
        return _compareText([track.albumArtist, ...?track.artists].whereType<String>().join(" "), rule);
      case SmartField.album:
        return _compareText(track.album, rule);
      case SmartField.genre:
        return _compareText((track.genres ?? []).join(" "), rule);
    }
  }

  bool _compareText(String? field, SmartRule rule) {
    final f = (field ?? "").toLowerCase();
    final v = rule.value.toLowerCase();
    switch (rule.op) {
      case SmartOp.equals:
        return f == v;
      case SmartOp.notEquals:
        return f != v;
      case SmartOp.contains:
        return v.isEmpty || f.contains(v);
      case SmartOp.greaterThan:
        return f.compareTo(v) > 0;
      case SmartOp.lessThan:
        return f.compareTo(v) < 0;
    }
  }

  bool _compareNum(int? field, SmartRule rule) {
    final target = int.tryParse(rule.value.trim());
    if (target == null || field == null) return false;
    switch (rule.op) {
      case SmartOp.equals:
        return field == target;
      case SmartOp.notEquals:
        return field != target;
      case SmartOp.greaterThan:
        return field > target;
      case SmartOp.lessThan:
        return field < target;
      case SmartOp.contains:
        return field == target;
    }
  }

  void _sort(List<BaseItemDto> items, SmartPlaylist playlist) {
    int cmp(BaseItemDto a, BaseItemDto b) {
      switch (playlist.sort) {
        case SmartSort.title:
          return (a.name ?? "").toLowerCase().compareTo((b.name ?? "").toLowerCase());
        case SmartSort.artist:
          return (a.albumArtist ?? "").toLowerCase().compareTo((b.albumArtist ?? "").toLowerCase());
        case SmartSort.album:
          return (a.album ?? "").toLowerCase().compareTo((b.album ?? "").toLowerCase());
        case SmartSort.year:
          return (a.productionYear ?? 0).compareTo(b.productionYear ?? 0);
        case SmartSort.playCount:
          return (a.userData?.playCount ?? 0).compareTo(b.userData?.playCount ?? 0);
        case SmartSort.random:
          return 0;
      }
    }

    if (playlist.sort == SmartSort.random) {
      items.shuffle();
      return;
    }
    items.sort(cmp);
    if (playlist.descending) {
      final reversed = items.reversed.toList();
      items
        ..clear()
        ..addAll(reversed);
    }
  }
}
