import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/library_shortcut.dart';
import 'package:get_it/get_it.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';

class ShortcutService {
  ShortcutService();

  static final _log = Logger("ShortcutService");

  static const maxPins = 6;
  static const maxSearchHistory = 20;

  Isar get _isar => GetIt.instance<Isar>();

  final List<void Function()> _listeners = [];
  void addListener(void Function() listener) => _listeners.add(listener);
  void _notify() {
    for (final listener in _listeners) {
      listener();
    }
  }

  List<PinnedItem> get pins =>
      _isar.pinnedItems.where().sortBySortIndex().thenByPinnedAt().findAllSync();

  bool isPinned(BaseItemId id) => _isar.pinnedItems.getSync(PinnedItem.fastHash(id.raw)) != null;

  bool get isFull => pins.length >= maxPins;

  Future<bool> pin(BaseItemDto item) async {
    if (isPinned(item.id)) return true;
    if (isFull) return false;

    final entry = PinnedItem(
      itemId: item.id.raw,
      name: item.name ?? "Unknown",
      subtitle: item.albumArtist,
      type: item.type ?? "MusicAlbum",
      pinnedAt: DateTime.now(),
      sortIndex: pins.length,
    );

    _isar.writeTxnSync(() => _isar.pinnedItems.putSync(entry));
    _notify();
    _log.fine("Pinned '${entry.name}'");
    return true;
  }

  Future<void> unpin(BaseItemId id) async {
    _isar.writeTxnSync(() => _isar.pinnedItems.deleteSync(PinnedItem.fastHash(id.raw)));
    _notify();
  }

  Future<void> togglePin(BaseItemDto item) async {
    if (isPinned(item.id)) {
      await unpin(item.id);
    } else {
      await pin(item);
    }
  }

  Future<void> reorderPins(List<PinnedItem> ordered) async {
    _isar.writeTxnSync(() {
      for (final (index, pin) in ordered.indexed) {
        pin.sortIndex = index;
        _isar.pinnedItems.putSync(pin);
      }
    });
    _notify();
  }

  List<SearchHistoryEntry> get recentSearches =>
      _isar.searchHistoryEntrys.where().sortBySearchedAtDesc().limit(maxSearchHistory).findAllSync();

  Future<void> recordSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    _isar.writeTxnSync(() {
      _isar.searchHistoryEntrys.putSync(SearchHistoryEntry(query: trimmed, searchedAt: DateTime.now()));

      final all = _isar.searchHistoryEntrys.where().sortBySearchedAtDesc().findAllSync();
      if (all.length > maxSearchHistory) {
        for (final stale in all.skip(maxSearchHistory)) {
          _isar.searchHistoryEntrys.deleteSync(stale.isarId);
        }
      }
    });
  }

  Future<void> removeSearch(String query) async {
    _isar.writeTxnSync(
      () => _isar.searchHistoryEntrys.deleteSync(PinnedItem.fastHash(query.toLowerCase())),
    );
  }

  Future<void> clearSearchHistory() async {
    _isar.writeTxnSync(() => _isar.searchHistoryEntrys.clearSync());
    _log.info("Cleared the search history");
  }
}
