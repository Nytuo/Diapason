import 'package:diapason/components/MusicScreen/item_wrapper.dart';
import 'package:diapason/components/MusicScreen/sort_and_filter_row.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_models.dart';
import 'package:diapason/services/music_screen_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "All" search tab: a few top results of every library content type in one
/// scrolling page (YouTube is excluded, it has its own tab). Each section has a
/// "See all" button that hands off to the per-type view, which acts as a filter.
class SearchAllResults extends ConsumerWidget {
  const SearchAllResults({super.key, required this.query, required this.onSeeAll, this.perSection = 5});

  final String query;
  final ValueChanged<ContentType> onSeeAll;
  final int perSection;

  static const sections = [
    (ContentType.albums, "Albums"),
    (ContentType.performingArtists, "Artists"),
    (ContentType.tracks, "Songs"),
    (ContentType.playlists, "Playlists"),
  ];

  static QueueItemSource get _source => QueueItemSource.rawId(
    type: QueueItemSourceType.allTracks,
    name: const QueueItemSourceName(type: QueueItemSourceNameType.shuffleAll),
    id: "shuffleAll",
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = <ContentType, AsyncValue<List<BaseItemDto>?>>{};
    for (final (tab, _) in sections) {
      final request = MusicScreenPlayable(
        tab: tab,
        library: currentLibraryPlaceholder,
        source: _source,
        sortConfig: ref.watch(resolveSortProvider(_controllerFor(tab))).copyWithSearch(query),
      );
      results[tab] = ref.watch(loadHomeSectionItemsProvider(request: request, startIndex: 0, limit: perSection));
    }

    final loading = results.values.any((r) => r.isLoading && !r.hasValue);
    final allEmpty = results.values.every((r) => (r.value ?? const []).isEmpty);
    if (allEmpty) {
      return Center(
        child: loading ? const CircularProgressIndicator.adaptive() : Text('No results for "$query"'),
      );
    }

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (final (tab, title) in sections)
          if ((results[tab]!.value ?? const []).isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                  TextButton(onPressed: () => onSeeAll(tab), child: const Text("See all")),
                ],
              ),
            ),
            for (final item in results[tab]!.value!) ItemWrapper(key: ValueKey("${tab.name}:${item.id}"), item: item),
          ],
        const SizedBox(height: 24),
      ],
    );
  }

  // Sort defaults per type, without touching the user's tab settings.
  static final Map<ContentType, SortAndFilterController> _controllers = {};
  static SortAndFilterController _controllerFor(ContentType tab) =>
      _controllers[tab] ??= SortAndFilterController.trackSettings(tab);
}
