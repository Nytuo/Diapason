import 'dart:math';

import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/album_screen_provider.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/item_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../components/MusicScreen/sort_and_filter_row.dart';
import '../services/music_screen_provider.dart';
import 'jellyfin_models.dart';

part 'music_models.g.dart';

/*FutureProviderFamily<List<ChildType>, FinampPlayableWithChildren<ChildType>> getChildren<ChildType> = FutureProvider.family((
  Ref ref,
  FinampPlayableWithChildren item,
) {
  return ref.watch(item.getChildren(ref));
});*/

// Public interface types:
// FinampPlayable
// FinampDisplayable
// FinampPagable
// FinampSortable

// Question
// - should playables be loaded by user or by queue?  If queue, we could attach provider lifecycle to queueservice.  I'm not sure that matters?
// should probably just add a provider container that resolves slice by reading providerContainer.  I think ref is mostly just to help read
// children, where we do want to allow actual watching.
// How does hive handle extends?  Try builder and see
// Can we get generic provider family with code builder?  Also need to test if cast actually works.

// TODO convert to generators
// TODO is makign paged a generic thing worthwhile?
// Is the typing dumb?  Maybe I should just be attaching bool flags for playable, and maybe even paging.
// stuff like the slice provider could just special case all the weird items.
// Is the two-step paging reasonably efficent?

// TODO consider alternative design
// It looks like the extra seled classes do get properly ignored, it's just mixins and whatnot that are problematic.
// So just remove all mixins, make classes empty except insstance variables and equals.
// Should still be able to make privite sealed helper classes with mix of base variable
// All actual work will be done exclusivly in providers switching over the subclasses.
// Also, rename item base to FinampPlayableDto
// Providers don't support generics, so just duplicate/split based on the types!
// I think it's probably just track children vs non-track children that really need a difference anyway.

FutureProviderFamily<List<FinampUnpagedPlayable>, FinampUnpagedDisplayable> getChildrenProvider = FutureProvider.family(
  (Ref ref, FinampUnpagedDisplayable item) {
    return item.getChildren(ref);
  },
);

class PageRequest<T extends FinampUnpagedPlayable> {
  const PageRequest({required this.item, required this.startingIndex, required this.limit});
  final FinampPagedDisplayable<T> item;
  final int startingIndex;
  final int limit;

  @override
  bool operator ==(Object other) {
    return other is PageRequest && other.item == item && other.startingIndex == startingIndex && other.limit == limit;
  }

  @override
  int get hashCode => Object.hash(item, startingIndex, limit);
}

FutureProvider<List<ChildType>> getPagedChildrenProvider<ChildType extends FinampUnpagedPlayable>(
  PageRequest<ChildType> item,
) {
  return _getPagedChildrenProvider(item) as FutureProvider<List<ChildType>>;
}

FutureProviderFamily<List<FinampUnpagedPlayable>, PageRequest<FinampUnpagedPlayable>> _getPagedChildrenProvider =
    FutureProvider.family((Ref ref, PageRequest request) {
      return request.item.getPagedChildren(ref, startingIndex: request.startingIndex, limit: request.limit);
    });

const sliceMaxPreTracks = 20;

@riverpod
Future<PlayableSlice> getPlayerSlice(
  Ref ref, {
  required FinampPlayable item,
  required int startingOffset,
  int? limit,
}) async {
  switch (item) {
    case FinampUnpagedPlayable():
      final slice = await item.getPlayable(ref);
      return slice.fromIndex(startingOffset, limit: limit);
    case FinampPagedPlayable():
      bool hardLimit = true;
      if (limit == null) {
        limit = ref.watch(finampSettingsProvider.trackShuffleItemCount);
        hardLimit = false;
      }
      int preTracks = 0;
      // If we are working directly with tracks, add some extra to flesh out the previous tracks section
      // TODO should this be in pagedPlayable so we could maybe support in other scenarios?  Would get messy.
      if (item is FinampPagedPlayable<Track>) {
        preTracks = min(min(20, (limit! / 10.0).ceil()), startingOffset);
      }
      return (await item.getPagedPlayable(
        ref,
        startingChild: startingOffset - preTracks,
        trackLimit: limit! + preTracks,
        hardLimit: hardLimit,
      )).fromIndex(preTracks);
  }
}

// We should be relying on the music screen provider for the paged slices/children.

//
//
//   Core public interfaces
//
//

// Note that we reserve fields 0-9 for the specific instances.  Our fields will be included in those instances,
// so we start numbering them at 10.
sealed class FinampDisplayableOrPlayable {}

sealed class FinampDisplayable<ChildType extends FinampPlayable>
    with _NeedsEquals
    implements FinampDisplayableOrPlayable {
  const FinampDisplayable();
}

sealed class FinampPlayable with _NeedsEquals implements FinampDisplayableOrPlayable {
  const FinampPlayable({required this.source});

  final QueueItemSource source;
  String get id;
}

abstract class FinampPagedDisplayable<ChildType extends FinampPlayable> extends FinampDisplayable<ChildType> {
  const FinampPagedDisplayable();
  Future<List<ChildType>> getPagedChildren(Ref ref, {required int startingIndex, required int limit});
}

abstract class FinampUnpagedDisplayable<ChildType extends FinampUnpagedPlayable> extends FinampDisplayable<ChildType> {
  const FinampUnpagedDisplayable();
  Future<List<ChildType>> getChildren(Ref ref);
}

abstract class FinampPagedPlayable<ChildType extends FinampPlayable> extends FinampPlayable
    implements FinampPagedDisplayable<ChildType> {
  const FinampPagedPlayable({required super.source});

  // TODO should there be a bool to allow supplying the overshoots generated while calculating playables?

  Future<PlayableSlice> getPagedPlayable(
    Ref ref, {
    required int startingChild,
    required int trackLimit,
    bool hardLimit,
  });

  /// Get the playable tracks from this item in a shuffled order.
  /// Default implementation allows the player to perform the actual shuffling,
  /// but some playables may override this with a more efficient method.
  Future<PlayableSlice> getPagedShuffled(Ref ref, {required int trackLimit, bool hardLimit});
}

abstract class FinampUnpagedPlayable extends FinampPlayable {
  const FinampUnpagedPlayable({required super.source});

  Future<PlayableSlice> getPlayable(Ref ref);

  Future<PlayableSlice> getShuffled(Ref ref) => getPlayable(ref).then((value) => value.shuffle());
}

//
//
//   Additional public interfaces
//
//

abstract class FinampPlayableItem extends FinampUnpagedPlayable {
  const FinampPlayableItem(this.item, {required super.source});

  final BaseItemDto item;

  @override
  String get id => item.id.raw;

  @override
  bool equalsHelperChain(Object other) {
    return other is FinampPlayableItem && item == other.item && super.equalsHelperChain(other);
  }

  @override
  int get hashHelperChain => Object.hash(item, super.hashHelperChain);
}

// We only expect this to be put on FinampDisplayable, but we avoid extending that to stay out of the sealed class values.
abstract class FinampSortable {
  const FinampSortable({required this.sortConfig});

  final SortAndFilterConfiguration sortConfig;

  //FinampSortable copyWith(SortAndFilterConfiguration newSort);
}

//
//
//  Public slice classes to return
//
//

final class PlayableSlice {
  PlayableSlice({required this.items, required this.startingIndex, required this.source, required this.shuffleState})
    : assert(items.every((x) => BaseItemDtoType.fromItem(x) == BaseItemDtoType.track));

  final List<BaseItemDto> items;
  final int startingIndex;
  final QueueItemSource source;
  final SliceShuffleState shuffleState;

  PlayableSlice shuffle() {
    return PlayableSlice(
      items: items,
      startingIndex: 0,
      source: source,
      shuffleState: shuffleState == SliceShuffleState.linear ? SliceShuffleState.playerShuffled : shuffleState,
    );
  }

  // TODO is this useful?
  PlayableSlice preShuffle() {
    final clonedItems = List<BaseItemDto>.from(items);
    clonedItems.shuffle();
    return PlayableSlice(
      items: clonedItems,
      startingIndex: 0,
      source: source,
      shuffleState: SliceShuffleState.preShuffled,
    );
  }

  PlayableSlice fromIndex(int newIndex, {int? limit}) {
    newIndex = newIndex.clamp(0, max(0, items.length - 1));
    if (limit == null) {
      return PlayableSlice(items: items, startingIndex: newIndex, source: source, shuffleState: shuffleState);
    }

    final excess = limit - (items.length - newIndex);
    final preTracks = excess.clamp(0, newIndex);

    return PlayableSlice(
      items: items.slice(newIndex - preTracks, min(newIndex + limit, items.length)),
      startingIndex: preTracks,
      source: source,
      shuffleState: shuffleState,
    );
  }
}

// TODO add class extends PlayableSlice with a shuffle order for player already prepared to allow passing queues around easily?

enum SliceShuffleState { preShuffled, playerShuffled, linear }

//
//
//   Private mixins
//
//

// TODO need to add sort/filter config somewhere - overlapping var in PlayableItem and FinampPlayableWithChildren<ChildType?
// playable should stay ultra-generic - I think as-is we could even fir in queues?

/*
mixin _UnpagedDisplayable<ChildType extends FinampPagedPlayable> implements FinampUnpagedDisplayable<ChildType> {
  @override
  Future<List<ChildType>> getPagedChildren(Ref ref, {required int startingIndex, required int limit}) async {
    final children = await getChildren(ref);
    final safeStart = startingIndex.clamp(0, children.length);
    final safeEnd = (startingIndex + limit).clamp(safeStart, children.length);
    return children.slice(safeStart, safeEnd);
  }
}

mixin _UnpagedPlayable implements FinampUnpagedPlayable {
  @override
  Future<PlayableSlice> getPagedPlayable(Ref ref, {required int startingIndex, required int limit}) =>
      getPlayable(ref).then((x) => x.fromIndex(startingIndex, limit: limit));

  @override
  Future<PlayableSlice> getPagedShuffled(Ref ref, {required int limit}) =>
      getShuffled(ref).then((x) => x.fromIndex(0, limit: limit));

  @override
  Future<PlayableSlice> getShuffled(Ref ref) => getPlayable(ref).then((value) => value.shuffle());
}
 */

mixin _UnpagedPlayableChildren<ChildType extends FinampUnpagedPlayable>
    implements FinampUnpagedDisplayable<ChildType>, FinampUnpagedPlayable {
  @override
  Future<PlayableSlice> getPlayable(Ref ref) async {
    final children = await getChildren(ref);
    final output = <BaseItemDto>[];
    for (final child in children) {
      final childSlice = await child.getPlayable(ref);
      output.addAll(childSlice.items);
    }
    return PlayableSlice(items: output, startingIndex: 0, source: source, shuffleState: SliceShuffleState.linear);
  }
}

mixin _PagedPlayableChildren<ChildType extends FinampUnpagedPlayable>
    implements FinampPagedDisplayable<ChildType>, FinampPagedPlayable<ChildType> {
  int get normalChildSize;

  @override
  /// Gets a slice of the component tracks.  Note the the starting offset is based on the pagable's children, not the
  /// final tracks, so it should be used with care.  The limit is applied to the output tracks themselves, however.
  Future<PlayableSlice> getPagedPlayable(
    Ref ref, {
    required int startingChild,
    required int trackLimit,
    bool hardLimit = true,
  }) async {
    // Drop normal child size by half to reduce the odds of undershooting.  Clamps to a minimum expected child size of one.
    int childLimit = (trackLimit / min(1.0, normalChildSize / 2.0)).ceil();
    final pager = ref.read(pagedContentProvider(this).notifier);
    final children = await pager.loadSlice(startingChild, childLimit);
    final output = <BaseItemDto>[];
    for (final child in children) {
      final childSlice = await child.getPlayable(ref);
      output.addAll(childSlice.items);
      if (output.length > trackLimit) {
        break;
      }
    }
    final slicedOut = output.slice(0, hardLimit ? min(trackLimit, output.length) : null);
    return PlayableSlice(items: slicedOut, startingIndex: 0, source: source, shuffleState: SliceShuffleState.linear);
  }

  @override
  Future<PlayableSlice> getPagedShuffled(
    Ref ref, {
    required int trackLimit,
    bool shuffleByChild = false,
    bool hardLimit = true,
  }) async {
    // Drop child size by 1/3 to make sure we get enough children.  Smaller value then playable used
    // to give more room for shuffling.
    int childLimit = (trackLimit / min(1.0, normalChildSize / 3.0)).ceil();
    // TODO add shuffle all children option?  would only work if sortable + we add update sortconfig method.
    final pager = ref.read(pagedContentProvider(this).notifier);
    final children = await pager.loadSlice(0, childLimit);
    if (shuffleByChild) {
      children.shuffle();
    }
    final output = <BaseItemDto>[];
    for (final child in children) {
      final childSlice = await child.getPlayable(ref);
      output.addAll(childSlice.items);
      if (output.length > trackLimit) {
        break;
      }
    }
    final slicedOut = output.slice(0, hardLimit ? min(trackLimit, output.length) : null);
    return PlayableSlice(
      items: slicedOut,
      startingIndex: 0,
      source: source,
      shuffleState: shuffleByChild ? SliceShuffleState.linear : SliceShuffleState.playerShuffled,
    );
  }
}

abstract class _SortableItem<ChildType extends FinampUnpagedPlayable> extends FinampPlayableItem
    implements FinampSortable, FinampUnpagedDisplayable<ChildType> {
  _SortableItem(super.item, {required super.source, required this.sortConfig})
    : assert(() {
        ContentType type = [BaseItemDtoType.album, BaseItemDtoType.playlist].contains(BaseItemDtoType.fromItem(item))
            ? ContentType.inPlaylist
            : ContentType.tracks;
        final controller = SortAndFilterController(startingConfig: sortConfig, contentType: type);
        final resolvedConfig = GetIt.instance<ProviderContainer>().read(resolveSortProvider(controller));
        return sortConfig == resolvedConfig;
      }());

  @override
  final SortAndFilterConfiguration sortConfig;

  @override
  bool equalsHelperChain(Object other) {
    return other is _SortableItem && sortConfig == other.sortConfig && super.equalsHelperChain(other);
  }

  @override
  int get hashHelperChain => Object.hash(sortConfig, super.hashHelperChain);
}

abstract class _SortablePagedPlayable<ChildType extends FinampPlayable> extends FinampPagedPlayable<ChildType>
    implements FinampSortable {
  _SortablePagedPlayable({required super.source, required this.sortConfig});

  @override
  final SortAndFilterConfiguration sortConfig;

  @override
  bool equalsHelperChain(Object other) {
    return other is _SortablePagedPlayable && sortConfig == other.sortConfig && super.equalsHelperChain(other);
  }

  @override
  int get hashHelperChain => Object.hash(sortConfig, super.hashHelperChain);
}

mixin _NeedsEquals {
  @override
  bool operator ==(Object other) => equalsHelper(other) && equalsHelperChain(other);

  @override
  int get hashCode => Object.hash(hashHelper, hashHelperChain);

  bool equalsHelper(Object other);
  int get hashHelper;

  @mustCallSuper
  bool equalsHelperChain(Object other) => true;

  @mustCallSuper
  int get hashHelperChain => 0;
}

//
//
//   Concrete instances
//
//

class Track extends FinampPlayableItem {
  Track(super.item, {required super.source}) {
    if (BaseItemDtoType.fromItem(item) != BaseItemDtoType.track) {
      throw UnimplementedError();
    }
  }

  @override
  Future<PlayableSlice> getPlayable(Ref ref) async {
    return PlayableSlice(items: [item], startingIndex: 0, source: source, shuffleState: SliceShuffleState.linear);
  }

  @override
  Future<PlayableSlice> getShuffled(Ref ref) => getPlayable(ref).then((value) => value.shuffle());

  @override
  bool equalsHelper(Object other) {
    return other is Track && equalsHelperChain(other);
  }

  @override
  int get hashHelper => Object.hash(Track, hashHelperChain);
}

class Album extends FinampPlayableItem with _UnpagedPlayableChildren<Track> {
  Album(super.item, {required super.source}) {
    if (BaseItemDtoType.fromItem(item) != BaseItemDtoType.album) {
      throw UnimplementedError();
    }
  }

  factory Album.fromItem(BaseItemDto item) => Album(item, source: QueueItemSource.fromBaseItem(item));

  @override
  Future<List<Track>> getChildren(Ref ref) async {
    final items = await ref.watch(getAlbumOrPlaylistTracksProvider(item).future);
    return items.$2.map((item) => Track(item, source: source)).toList();
  }

  @override
  bool equalsHelper(Object other) => other is Album;

  @override
  int get hashHelper => (Album as Object).hashCode;
}

class Playlist extends _SortableItem<Track> with _UnpagedPlayableChildren<Track> {
  Playlist(super.item, {required super.source, required super.sortConfig}) {
    if (BaseItemDtoType.fromItem(item) != BaseItemDtoType.playlist) {
      throw UnimplementedError();
    }
  }

  factory Playlist.fromItem(BaseItemDto item, {SortAndFilterConfiguration? sortConfig}) => Playlist(
    item,
    source: QueueItemSource.fromBaseItem(item),
    sortConfig: sortConfig ?? SortAndFilterConfiguration.defaultInAlbumSort,
  );

  @override
  Future<List<Track>> getChildren(Ref ref) async {
    final items = await ref.watch(getSortedPlaylistTracksProvider(item, sortConfig).future);
    return items.$2.map((item) => Track(item, source: source)).toList();
  }

  @override
  bool equalsHelper(Object other) => other is Playlist;

  @override
  int get hashHelper => (Playlist as Object).hashCode;
}

// TODO add shuffle grouping control?

class MusicScreenPlayable<ChildType extends FinampPlayableItem> extends _SortablePagedPlayable<ChildType>
    with _PagedPlayableChildren<ChildType> {
  final ContentType tab;
  final LibraryOrItemId library;

  MusicScreenPlayable._({required this.tab, required this.library, required super.source, required super.sortConfig}) {
    assert(() {
      final controller = SortAndFilterController(startingConfig: sortConfig, contentType: tab);
      final resolvedConfig = GetIt.instance<ProviderContainer>().read(resolveSortProvider(controller));
      return sortConfig == resolvedConfig;
    }());
    switch (tab) {
      case ContentType.albums:
      case ContentType.playlists:
      case ContentType.genres:
      case ContentType.tracks:
      case ContentType.performingArtists:
      case ContentType.albumArtists:
        break;
      case ContentType.home:
      case ContentType.genericArtists:
      case ContentType.inPlaylist:
      case ContentType.mixed:
        throw UnsupportedError("Invalid content type $tab for music screen tab.");
    }
  }

  static MusicScreenPlayable build({
    required ContentType tab,
    required LibraryOrItemId library,
    required QueueItemSource source,
    required SortAndFilterConfiguration sortConfig,
  }) {
    switch (tab) {
      case ContentType.albums:
      case ContentType.performingArtists:
      case ContentType.albumArtists:
      case ContentType.playlists:
      case ContentType.genres:
      case ContentType.tracks:
        return MusicScreenPlayable<Track>._(tab: tab, library: library, source: source, sortConfig: sortConfig);
      case ContentType.inPlaylist:
      case ContentType.genericArtists:
      case ContentType.home:
      case ContentType.mixed:
        throw UnsupportedError("Invalid content type $tab for music screen tab.");
    }
  }

  factory MusicScreenPlayable({
    required ContentType tab,
    required LibraryOrItemId library,
    required QueueItemSource source,
    required SortAndFilterConfiguration sortConfig,
  }) {
    switch (tab) {
      case ContentType.albums:
        return MusicScreenPlayable<Album>._(tab: tab, library: library, source: source, sortConfig: sortConfig)
            as MusicScreenPlayable<ChildType>;
      case ContentType.playlists:
        return MusicScreenPlayable<Playlist>._(tab: tab, library: library, source: source, sortConfig: sortConfig)
            as MusicScreenPlayable<ChildType>;
      case ContentType.performingArtists:
      case ContentType.albumArtists:
      case ContentType.genres:
        return MusicScreenPlayable<GenericPlayableItem>._(
              tab: tab,
              library: library,
              source: source,
              sortConfig: sortConfig,
            )
            as MusicScreenPlayable<ChildType>;
      case ContentType.tracks:
        return MusicScreenPlayable<Track>._(tab: tab, library: library, source: source, sortConfig: sortConfig)
            as MusicScreenPlayable<ChildType>;
      case ContentType.inPlaylist:
      case ContentType.genericArtists:
      case ContentType.home:
      case ContentType.mixed:
        throw UnsupportedError("Invalid content type $tab for music screen tab.");
    }
  }

  FinampPlayableItem _buildChild(BaseItemDto item) {
    switch (tab) {
      case ContentType.tracks:
        return Track(item, source: source);
      case ContentType.albums:
        return Album(item, source: source);
      case ContentType.playlists:
        return Playlist(item, source: source, sortConfig: sortConfig);
      case ContentType.genres:
      case ContentType.performingArtists:
      case ContentType.albumArtists:
        // TODO return real items
        return GenericPlayableItem(item, sortConfig: sortConfig);
      case ContentType.home:
      case ContentType.genericArtists:
      case ContentType.inPlaylist:
      case ContentType.mixed:
        throw UnsupportedError("Invalid content type $tab for music screen tab.");
    }
  }

  HomeScreenSectionConfiguration get section => HomeScreenSectionConfiguration(
    type: HomeScreenSectionType.tabView,
    itemId: library,
    contentType: tab,
    sortAndFilterConfiguration: sortConfig,
  );

  @override
  Future<List<ChildType>> getPagedChildren(Ref ref, {required int startingIndex, required int limit}) async {
    final children =
        await ref.watch(
          loadHomeSectionItemsProvider(sectionInfo: section, startIndex: startingIndex, limit: limit).future,
        ) ??
        [];
    return children.map((x) => _buildChild(x) as ChildType).toList();
  }

  @override
  int get normalChildSize => switch (tab) {
    ContentType.albums => 10,
    ContentType.playlists => 20,
    ContentType.genres => 30,
    ContentType.tracks => 1,
    ContentType.performingArtists => 30,
    ContentType.albumArtists => 3,
    ContentType.home => throw UnimplementedError(),
    ContentType.genericArtists => throw UnimplementedError(),
    ContentType.inPlaylist => throw UnimplementedError(),
    ContentType.mixed => throw UnimplementedError(),
  };

  @override
  bool equalsHelper(Object other) =>
      other is MusicScreenPlayable && tab == other.tab && library == other.library && equalsHelperChain(other);

  @override
  int get hashHelper => Object.hash(tab, library, hashHelperChain);

  @override
  String get id => "finamp-music-screen-$hashCode";
}

// TODO do we need this to have an item?  Or can it be a generic prebaked section?
class AlbumDisc extends FinampPlayableItem with _UnpagedPlayableChildren<Track> {
  AlbumDisc(super.item, {required this.tracks})
    : assert(
        tracks.every((e) {
          return e.parentIndexNumber == tracks.first.parentIndexNumber;
        }),
        // TODO disc-specific source?
      ),
      assert(
        tracks.every((e) {
          return e.albumId == item.id;
        }),
        // TODO disc-specific source?
      ),
      super(source: QueueItemSource.fromBaseItem(item));
  final List<BaseItemDto> tracks;

  @override
  Future<List<Track>> getChildren(Ref<Object?> ref) async {
    return tracks.map((x) => Track(x, source: source)).toList();
  }

  @override
  bool equalsHelper(Object other) => other is AlbumDisc && listEquals(tracks, other.tracks);

  @override
  int get hashHelper => Object.hashAll(tracks);
}

class PrecalculatedPlayable extends FinampUnpagedPlayable with _UnpagedPlayableChildren<Track> {
  const PrecalculatedPlayable({required super.source, required this.tracks});
  final List<BaseItemDto> tracks;

  @override
  Future<List<Track>> getChildren(Ref<Object?> ref) async {
    return tracks.map((x) => Track(x, source: source)).toList();
  }

  @override
  String get id => "finamp-music-screen-${source.hashCode}";

  @override
  bool equalsHelper(Object other) => other is PrecalculatedPlayable && listEquals(tracks, other.tracks);

  @override
  int get hashHelper => Object.hashAll(tracks);
}

class GenericPlayableItem extends _SortableItem<Track> with _UnpagedPlayableChildren<Track> {
  GenericPlayableItem(super.item, {SortAndFilterConfiguration? sortConfig})
    : super(
        source: QueueItemSource.fromBaseItem(item),
        sortConfig: sortConfig ?? SortAndFilterConfiguration.defaultSort,
      );

  factory GenericPlayableItem.defaultSort(BaseItemDto item) =>
      GenericPlayableItem(item, sortConfig: SortAndFilterConfiguration.defaultInAlbumSort);

  @override
  Future<List<Track>> getChildren(Ref ref) async {
    final items = await loadChildTracksFromBaseItem(item: item, sortConfig: sortConfig);
    return items.map((item) => Track(item, source: source)).toList();
  }

  @override
  bool equalsHelper(Object other) => other is Playlist;

  @override
  int get hashHelper => (Playlist as Object).hashCode;
}

class LatestQueues extends FinampUnpagedDisplayable {
  LatestQueues();

  @override
  Future<List<FinampUnpagedPlayable>> getChildren(Ref ref) {
    // TODO move to standard methods?
    throw UnimplementedError();
  }

  @override
  bool equalsHelper(Object other) {
    return other is LatestQueues && equalsHelperChain(other);
  }

  @override
  int get hashHelper => Object.hash(LatestQueues, hashHelperChain);
}

class InstantMix extends FinampPlayableItem {
  InstantMix(super.item)
    : super(
        source: QueueItemSource(
          type: switch (BaseItemDtoType.fromItem(item)) {
            BaseItemDtoType.track => QueueItemSourceType.trackMix,
            BaseItemDtoType.album => QueueItemSourceType.albumMix,
            BaseItemDtoType.artist => QueueItemSourceType.artistMix,
            BaseItemDtoType.genre => QueueItemSourceType.genreMix,
            _ => QueueItemSourceType.unknown,
          },
          name: QueueItemSourceName(
            type: item.name != null ? QueueItemSourceNameType.mix : QueueItemSourceNameType.instantMix,
            localizationParameter: item.name ?? "",
          ),
          id: item.id,
          item: item,
        ),
      );

  @override
  Future<PlayableSlice> getPlayable(Ref ref) async {
    throw UnimplementedError();
  }

  @override
  Future<PlayableSlice> getShuffled(Ref ref) => getPlayable(ref);

  @override
  bool equalsHelper(Object other) {
    return other is InstantMix && equalsHelperChain(other);
  }

  @override
  int get hashHelper => Object.hash(InstantMix, hashHelperChain);
}
