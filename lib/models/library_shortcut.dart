import 'package:isar_community/isar.dart';
import 'package:diapason/utils/isar_fast_hash.dart';

part 'library_shortcut.g.dart';

@collection
class PinnedItem {
  PinnedItem({
    required this.itemId,
    required this.name,
    this.subtitle,
    required this.type,
    required this.pinnedAt,
    this.sortIndex = 0,
  });

  Id get isarId => fastHash(itemId);

  @Index(unique: true, replace: true)
  final String itemId;

  String name;
  String? subtitle;

  String type;

  DateTime pinnedAt;
  int sortIndex;

  static int fastHash(String string) => isarFastHash(string);
}

@collection
class SearchHistoryEntry {
  SearchHistoryEntry({required this.query, required this.searchedAt});

  Id get isarId => PinnedItem.fastHash(query.toLowerCase());

  @Index(unique: true, replace: true)
  final String query;

  DateTime searchedAt;
}
