import 'package:diapason/models/library_shortcut.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("pin identity", () {
    test("an item is identified by its source-scoped id", () {
      // The same album on two servers is two different things, and pinning one
      // must not pin (or unpin) the other.
      final a = PinnedItem.fastHash("jf-1~album");
      final b = PinnedItem.fastHash("sub-1~album");

      expect(a, isNot(b));
    });

    test("the same id always hashes the same, so a pin survives a restart", () {
      expect(PinnedItem.fastHash("jf-1~album"), PinnedItem.fastHash("jf-1~album"));
    });
  });

  group("search history identity", () {
    SearchHistoryEntry entry(String query) => SearchHistoryEntry(query: query, searchedAt: DateTime(2026));

    test("de-duplicates case-insensitively", () {
      // Searching "Bowie" after "bowie" should move one entry to the top, not
      // create a second one that says the same thing.
      expect(entry("Bowie").isarId, entry("bowie").isarId);
      expect(entry("BOWIE").isarId, entry("bowie").isarId);
    });

    test("but keeps the query as the user typed it", () {
      expect(entry("Bowie").query, "Bowie");
    });

    test("different queries are different entries", () {
      expect(entry("bowie").isarId, isNot(entry("blondie").isarId));
    });
  });
}
