import 'package:isar/isar.dart';

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

  static int fastHash(String string) {
    var hash = 0xcbf29ce484222325;
    for (var i = 0; i < string.length; i++) {
      final codeUnit = string.codeUnitAt(i);
      hash ^= codeUnit >> 8;
      hash *= 0x100000001b3;
      hash ^= codeUnit & 0xFF;
      hash *= 0x100000001b3;
    }
    return hash;
  }
}

@collection
class SearchHistoryEntry {
  SearchHistoryEntry({required this.query, required this.searchedAt});

  Id get isarId => PinnedItem.fastHash(query.toLowerCase());

  @Index(unique: true, replace: true)
  final String query;

  DateTime searchedAt;
}
