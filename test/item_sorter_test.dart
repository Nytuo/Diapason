import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/item_sorter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sorting is expressed in Jellyfin's sort keys. Only Jellyfin can honour them
/// server-side, so every other source sorts what it fetched with these — before
/// this existed, choosing a sort did nothing at all on Subsonic, Plex or local
/// files.
void main() {
  BaseItemDto track({
    String name = "",
    String? album,
    int? year,
    int? playCount,
    String? created,
  }) => BaseItemDto(
    id: BaseItemId("sub-1~$name"),
    name: name,
    album: album,
    productionYear: year,
    dateCreated: created,
    userData: playCount == null ? null : UserItemDataDto(playCount: playCount, isFavorite: false, playbackPositionTicks: 0, played: false, key: name),
  );

  List<String?> names(List<BaseItemDto> items) => items.map((i) => i.name).toList();

  test("sorts by name, ignoring case", () {
    final items = [track(name: "banana"), track(name: "Apple"), track(name: "cherry")];

    expect(names(sortItemsByJellyfinKeys(items, "SortName", "Ascending")), ["Apple", "banana", "cherry"]);
  });

  test("reverses for a descending order", () {
    final items = [track(name: "a"), track(name: "c"), track(name: "b")];

    expect(names(sortItemsByJellyfinKeys(items, "SortName", "Descending")), ["c", "b", "a"]);
  });

  test("falls through to the next key when the first ties", () {
    final items = [
      track(name: "z", album: "Same"),
      track(name: "a", album: "Same"),
      track(name: "m", album: "Earlier"),
    ];

    // Album first, then name within the album.
    expect(names(sortItemsByJellyfinKeys(items, "Album,SortName", "Ascending")), ["m", "a", "z"]);
  });

  test("sorts by numbers and dates, not by their text", () {
    final byYear = [track(name: "new", year: 2020), track(name: "old", year: 1999)];
    expect(names(sortItemsByJellyfinKeys(byYear, "ProductionYear", "Ascending")), ["old", "new"]);

    final byPlays = [track(name: "few", playCount: 2), track(name: "many", playCount: 10)];
    // Textually "10" < "2"; numerically it is not.
    expect(names(sortItemsByJellyfinKeys(byPlays, "PlayCount", "Descending")), ["many", "few"]);

    final byDate = [
      track(name: "later", created: "2024-05-01T00:00:00Z"),
      track(name: "earlier", created: "2023-01-01T00:00:00Z"),
    ];
    expect(names(sortItemsByJellyfinKeys(byDate, "DateCreated", "Ascending")), ["earlier", "later"]);
  });

  test("puts items missing the sort value last, in both directions", () {
    // An album with no release date is not "the oldest".
    final items = [track(name: "unknown"), track(name: "dated", year: 2001)];

    expect(names(sortItemsByJellyfinKeys([...items], "ProductionYear", "Ascending")), ["dated", "unknown"]);
    expect(names(sortItemsByJellyfinKeys([...items], "ProductionYear", "Descending")), ["dated", "unknown"]);
  });

  test("leaves the order alone when there is no sort, rather than inventing one", () {
    final items = [track(name: "b"), track(name: "a")];

    expect(names(sortItemsByJellyfinKeys([...items], null, null)), ["b", "a"]);
    expect(names(sortItemsByJellyfinKeys([...items], "", "Ascending")), ["b", "a"]);
    // "Server order" is the empty key, and means whatever the source gave us.
    expect(names(sortItemsByJellyfinKeys([...items], "  ", "Ascending")), ["b", "a"]);
  });

  test("ignores a key it does not know instead of failing", () {
    final items = [track(name: "b"), track(name: "a")];

    expect(names(sortItemsByJellyfinKeys(items, "Budget,SortName", "Ascending")), ["a", "b"]);
  });

  test("random keeps every item, since it is a shuffle and not a comparison", () {
    final items = List.generate(20, (i) => track(name: "$i"));

    final shuffled = sortItemsByJellyfinKeys([...items], "Random", "Ascending");

    expect(shuffled.length, 20);
    expect(names(shuffled).toSet(), names(items).toSet());
  });
}
