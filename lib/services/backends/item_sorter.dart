import 'package:diapason/models/jellyfin_models.dart';

List<BaseItemDto> sortItemsByJellyfinKeys(List<BaseItemDto> items, String? sortBy, String? sortOrder) {
  final keys = (sortBy ?? "").split(",").map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
  if (keys.isEmpty) return items;

  if (keys.first == "Random") {
    return items..shuffle();
  }

  final descending = sortOrder?.toLowerCase().contains("desc") ?? false;

  items.sort((a, b) {
    for (final key in keys) {
      final (result, missing) = _compareBy(key, a, b);
      if (result == 0) continue;
      return missing ? result : (descending ? -result : result);
    }
    return 0;
  });
  return items;
}

(int, bool) _compareBy(String key, BaseItemDto a, BaseItemDto b) => switch (key) {
  "SortName" || "Name" => _text(a.nameForSorting ?? a.name, b.nameForSorting ?? b.name),
  "Album" => _text(a.album, b.album),
  "AlbumArtist" => _text(a.albumArtist, b.albumArtist),
  "Artist" => _text(a.artists?.join(", "), b.artists?.join(", ")),
  "CommunityRating" => _number(a.communityRating, b.communityRating),
  "CriticRating" => _number(a.criticRating, b.criticRating),
  "PlayCount" => _number(a.userData?.playCount, b.userData?.playCount),
  "ProductionYear" => _number(a.productionYear, b.productionYear),
  "Runtime" => _number(a.runTimeTicks, b.runTimeTicks),
  "IndexNumber" => _number(a.indexNumber, b.indexNumber),
  "ParentIndexNumber" => _number(a.parentIndexNumber, b.parentIndexNumber),
  "DateCreated" => _date(a.dateCreated, b.dateCreated),
  "PremiereDate" => _date(a.premiereDate, b.premiereDate),
  "DatePlayed" => _date(a.userData?.lastPlayedDate, b.userData?.lastPlayedDate),
  _ => (0, false),
};

(int, bool) _text(String? a, String? b) {
  if (a == null || b == null) return _missing(a, b);
  return (a.toLowerCase().compareTo(b.toLowerCase()), false);
}

(int, bool) _number(num? a, num? b) {
  if (a == null || b == null) return _missing(a, b);
  return (a.compareTo(b), false);
}

(int, bool) _date(String? a, String? b) {
  final dateA = a == null ? null : DateTime.tryParse(a.trim());
  final dateB = b == null ? null : DateTime.tryParse(b.trim());
  if (dateA == null || dateB == null) return _missing(dateA, dateB);
  return (dateA.compareTo(dateB), false);
}

(int, bool) _missing(Object? a, Object? b) {
  if (a == null && b == null) return (0, false);
  return (a == null ? 1 : -1, true);
}
