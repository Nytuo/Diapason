// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: deprecated_member_use_from_same_package, strict_raw_type, unused_element, unused_local_variable

// dart format off

part of 'music_screen_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(PagedContent)
final pagedContentProvider = PagedContentFamily._();

final class PagedContentProvider
    extends
        $NotifierProvider<
          PagedContent,
          PagingState<int, FinampDisplayableOrPlayable>
        > {
  PagedContentProvider._({
    required PagedContentFamily super.from,
    required FinampDisplayable<FinampDisplayableOrPlayable> super.argument,
  }) : super(
         retry: null,
         name: r'pagedContentProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$pagedContentHash();

  @override
  String toString() {
    return r'pagedContentProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  PagedContent create() => PagedContent();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(
    PagingState<int, FinampDisplayableOrPlayable> value,
  ) {
    return $ProviderOverride(
      origin: this,
      providerOverride:
          $SyncValueProvider<PagingState<int, FinampDisplayableOrPlayable>>(
            value,
          ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PagedContentProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$pagedContentHash() => r'1eaefb681245bb519b05fa4c4186d5a85d7a4fbe';

final class PagedContentFamily extends $Family
    with
        $ClassFamilyOverride<
          PagedContent,
          PagingState<int, FinampDisplayableOrPlayable>,
          PagingState<int, FinampDisplayableOrPlayable>,
          PagingState<int, FinampDisplayableOrPlayable>,
          FinampDisplayable<FinampDisplayableOrPlayable>
        > {
  PagedContentFamily._()
    : super(
        retry: null,
        name: r'pagedContentProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  PagedContentProvider call(
    FinampDisplayable<FinampDisplayableOrPlayable> request,
  ) => PagedContentProvider._(argument: request, from: this);

  @override
  String toString() => r'pagedContentProvider';
}

abstract class _$PagedContent
    extends $Notifier<PagingState<int, FinampDisplayableOrPlayable>> {
  late final _$args =
      ref.$arg as FinampDisplayable<FinampDisplayableOrPlayable>;
  FinampDisplayable<FinampDisplayableOrPlayable> get request => _$args;

  PagingState<int, FinampDisplayableOrPlayable> build(
    FinampDisplayable<FinampDisplayableOrPlayable> request,
  );
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<
              PagingState<int, FinampDisplayableOrPlayable>,
              PagingState<int, FinampDisplayableOrPlayable>
            >;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                PagingState<int, FinampDisplayableOrPlayable>,
                PagingState<int, FinampDisplayableOrPlayable>
              >,
              PagingState<int, FinampDisplayableOrPlayable>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}

@ProviderFor(loadHomeSectionItems)
final loadHomeSectionItemsProvider = LoadHomeSectionItemsFamily._();

final class LoadHomeSectionItemsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<BaseItemDto>?>,
          List<BaseItemDto>?,
          FutureOr<List<BaseItemDto>?>
        >
    with
        $FutureModifier<List<BaseItemDto>?>,
        $FutureProvider<List<BaseItemDto>?> {
  LoadHomeSectionItemsProvider._({
    required LoadHomeSectionItemsFamily super.from,
    required ({
      MusicScreenPlayable<FinampPlayableDto> request,
      int startIndex,
      int limit,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'loadHomeSectionItemsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$loadHomeSectionItemsHash();

  @override
  String toString() {
    return r'loadHomeSectionItemsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<List<BaseItemDto>?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<BaseItemDto>?> create(Ref ref) {
    final argument =
        this.argument
            as ({
              MusicScreenPlayable<FinampPlayableDto> request,
              int startIndex,
              int limit,
            });
    return loadHomeSectionItems(
      ref,
      request: argument.request,
      startIndex: argument.startIndex,
      limit: argument.limit,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is LoadHomeSectionItemsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$loadHomeSectionItemsHash() =>
    r'aeb08e20f1678578d16901595afbc62887a734be';

final class LoadHomeSectionItemsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<BaseItemDto>?>,
          ({
            MusicScreenPlayable<FinampPlayableDto> request,
            int startIndex,
            int limit,
          })
        > {
  LoadHomeSectionItemsFamily._()
    : super(
        retry: null,
        name: r'loadHomeSectionItemsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  LoadHomeSectionItemsProvider call({
    required MusicScreenPlayable<FinampPlayableDto> request,
    required int startIndex,
    required int limit,
  }) => LoadHomeSectionItemsProvider._(
    argument: (request: request, startIndex: startIndex, limit: limit),
    from: this,
  );

  @override
  String toString() => r'loadHomeSectionItemsProvider';
}

@ProviderFor(getJellyfinCollection)
final getJellyfinCollectionProvider = GetJellyfinCollectionFamily._();

final class GetJellyfinCollectionProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<BaseItemDto>?>,
          List<BaseItemDto>?,
          FutureOr<List<BaseItemDto>?>
        >
    with
        $FutureModifier<List<BaseItemDto>?>,
        $FutureProvider<List<BaseItemDto>?> {
  GetJellyfinCollectionProvider._({
    required GetJellyfinCollectionFamily super.from,
    required (BaseItemDto, SortAndFilterConfiguration) super.argument,
  }) : super(
         retry: null,
         name: r'getJellyfinCollectionProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getJellyfinCollectionHash();

  @override
  String toString() {
    return r'getJellyfinCollectionProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<List<BaseItemDto>?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<BaseItemDto>?> create(Ref ref) {
    final argument = this.argument as (BaseItemDto, SortAndFilterConfiguration);
    return getJellyfinCollection(ref, argument.$1, argument.$2);
  }

  @override
  bool operator ==(Object other) {
    return other is GetJellyfinCollectionProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getJellyfinCollectionHash() =>
    r'fdf13e534f5db51a2e07aa6c556e6a908c1f4e7c';

final class GetJellyfinCollectionFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<BaseItemDto>?>,
          (BaseItemDto, SortAndFilterConfiguration)
        > {
  GetJellyfinCollectionFamily._()
    : super(
        retry: null,
        name: r'getJellyfinCollectionProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetJellyfinCollectionProvider call(
    BaseItemDto collection,
    SortAndFilterConfiguration sortConfig,
  ) => GetJellyfinCollectionProvider._(
    argument: (collection, sortConfig),
    from: this,
  );

  @override
  String toString() => r'getJellyfinCollectionProvider';
}
