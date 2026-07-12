import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

/// A backend holding a fixed list of albums, recording how it was asked for them.
class _FakeBackend implements MediaBackend {
  _FakeBackend(String sourceId, MediaSourceKind kind, List<String> albumNames, {this.fails = false})
    : config = MediaSourceConfig(sourceId: sourceId, kind: kind, name: sourceId),
      _items = albumNames
          .map((n) => ItemMapper(sourceId).album(nativeId: n.toLowerCase(), name: n))
          .toList();

  @override
  final MediaSourceConfig config;

  final List<BaseItemDto> _items;
  final bool fails;

  /// What the aggregate actually asked this source for.
  int? seenStartIndex;
  int? seenLimit;

  @override
  String get sourceId => config.sourceId;

  @override
  Future<List<BaseItemDto>> getItems({
    BaseItemDto? parentItem,
    BaseItemId? libraryFilter,
    String? includeItemTypes,
    String? sortBy,
    String? sortOrder,
    String? searchTerm,
    String? filters,
    BaseItemId? genreFilter,
    bool? isFavorite,
    ArtistType? artistType,
    int? startIndex,
    int? limit,
  }) async {
    if (fails) throw StateError("this source is down");
    seenStartIndex = startIndex;
    seenLimit = limit;
    return _items;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

AggregateBackend _aggregateOver(List<_FakeBackend> backends) {
  final registry = BackendRegistry();
  for (final backend in backends) {
    registry.register(backend);
  }
  GetIt.instance.reset();
  GetIt.instance.registerSingleton<BackendRegistry>(registry);
  return AggregateBackend();
}

void main() {
  tearDown(() => GetIt.instance.reset());

  test("a single source is handed the request untouched", () async {
    // The no-regression guarantee: a Jellyfin-only library must page and filter
    // exactly as it did before aggregation existed.
    final jellyfin = _FakeBackend("jf-1", MediaSourceKind.jellyfin, ["A", "B"]);
    final aggregate = _aggregateOver([jellyfin]);

    await aggregate.getItems(startIndex: 40, limit: 20);

    expect(jellyfin.seenStartIndex, 40);
    expect(jellyfin.seenLimit, 20);
  });

  test("several sources are merged and sorted into one library", () async {
    final aggregate = _aggregateOver([
      _FakeBackend("jf-1", MediaSourceKind.jellyfin, ["Zebra", "Apple"]),
      _FakeBackend("sub-1", MediaSourceKind.subsonic, ["Mango"]),
    ]);

    final items = await aggregate.getItems();

    expect(items.map((i) => i.name), ["Apple", "Mango", "Zebra"]);
  });

  test("paging a merged library asks each source for the whole window", () async {
    // Item 3 of the merged library may come from any source, so server-side
    // paging cannot be delegated; each source is asked up to the window's end.
    final jellyfin = _FakeBackend("jf-1", MediaSourceKind.jellyfin, ["A", "C"]);
    final subsonic = _FakeBackend("sub-1", MediaSourceKind.subsonic, ["B", "D"]);
    final aggregate = _aggregateOver([jellyfin, subsonic]);

    final items = await aggregate.getItems(startIndex: 2, limit: 2);

    expect(jellyfin.seenStartIndex, 0);
    expect(jellyfin.seenLimit, 4, reason: "offset 2 + limit 2");
    expect(subsonic.seenLimit, 4);
    // The window is cut from the merged, sorted result.
    expect(items.map((i) => i.name), ["C", "D"]);
  });

  test("a failing source is skipped, not allowed to empty the library", () async {
    final aggregate = _aggregateOver([
      _FakeBackend("jf-1", MediaSourceKind.jellyfin, ["Alive"]),
      _FakeBackend("sub-1", MediaSourceKind.subsonic, ["Dead"], fails: true),
    ]);

    final items = await aggregate.getItems();

    expect(items.map((i) => i.name), ["Alive"]);
  });

  test("a disabled source contributes nothing", () async {
    final off = _FakeBackend("sub-1", MediaSourceKind.subsonic, ["Hidden"]);
    off.config.enabled = false;
    final aggregate = _aggregateOver([_FakeBackend("jf-1", MediaSourceKind.jellyfin, ["Shown"]), off]);

    final items = await aggregate.getItems();

    expect(items.map((i) => i.name), ["Shown"]);
  });

  test("with no sources at all, the library is empty rather than an error", () async {
    final aggregate = _aggregateOver([]);

    expect(await aggregate.getItems(), isEmpty);
  });
}
