// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: deprecated_member_use_from_same_package, strict_raw_type, unused_element, unused_local_variable

// dart format off

part of 'music_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(globalSearch)
final globalSearchProvider = GlobalSearchFamily._();

final class GlobalSearchProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<BaseItemDto>>,
          List<BaseItemDto>,
          FutureOr<List<BaseItemDto>>
        >
    with
        $FutureModifier<List<BaseItemDto>>,
        $FutureProvider<List<BaseItemDto>> {
  GlobalSearchProvider._({
    required GlobalSearchFamily super.from,
    required (String, {bool includeTracks}) super.argument,
  }) : super(
         retry: null,
         name: r'globalSearchProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$globalSearchHash();

  @override
  String toString() {
    return r'globalSearchProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<List<BaseItemDto>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<BaseItemDto>> create(Ref ref) {
    final argument = this.argument as (String, {bool includeTracks});
    return globalSearch(
      ref,
      argument.$1,
      includeTracks: argument.includeTracks,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GlobalSearchProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$globalSearchHash() => r'f5344b6313ca66d14912bc54543388ff88ca4fd2';

final class GlobalSearchFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<BaseItemDto>>,
          (String, {bool includeTracks})
        > {
  GlobalSearchFamily._()
    : super(
        retry: null,
        name: r'globalSearchProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GlobalSearchProvider call(String searchTerm, {required bool includeTracks}) =>
      GlobalSearchProvider._(
        argument: (searchTerm, includeTracks: includeTracks),
        from: this,
      );

  @override
  String toString() => r'globalSearchProvider';
}

@ProviderFor(resolveSection)
final resolveSectionProvider = ResolveSectionFamily._();

final class ResolveSectionProvider
    extends
        $FunctionalProvider<
          AsyncValue<FinampDisplayable<FinampPlayable>>,
          FinampDisplayable<FinampPlayable>,
          FutureOr<FinampDisplayable<FinampPlayable>>
        >
    with
        $FutureModifier<FinampDisplayable<FinampPlayable>>,
        $FutureProvider<FinampDisplayable<FinampPlayable>> {
  ResolveSectionProvider._({
    required ResolveSectionFamily super.from,
    required HomeScreenSectionConfiguration super.argument,
  }) : super(
         retry: null,
         name: r'resolveSectionProvider',
         isAutoDispose: false,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$resolveSectionHash();

  @override
  String toString() {
    return r'resolveSectionProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<FinampDisplayable<FinampPlayable>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<FinampDisplayable<FinampPlayable>> create(Ref ref) {
    final argument = this.argument as HomeScreenSectionConfiguration;
    return resolveSection(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ResolveSectionProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$resolveSectionHash() => r'fb1ca99c7145fa70fc9bbf931029039584829f8c';

final class ResolveSectionFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<FinampDisplayable<FinampPlayable>>,
          HomeScreenSectionConfiguration
        > {
  ResolveSectionFamily._()
    : super(
        retry: null,
        name: r'resolveSectionProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: false,
      );

  ResolveSectionProvider call(HomeScreenSectionConfiguration section) =>
      ResolveSectionProvider._(argument: section, from: this);

  @override
  String toString() => r'resolveSectionProvider';
}

@ProviderFor(getPlayableSlice)
final getPlayableSliceProvider = GetPlayableSliceFamily._();

final class GetPlayableSliceProvider
    extends
        $FunctionalProvider<
          AsyncValue<PlayableSlice>,
          PlayableSlice,
          FutureOr<PlayableSlice>
        >
    with $FutureModifier<PlayableSlice>, $FutureProvider<PlayableSlice> {
  GetPlayableSliceProvider._({
    required GetPlayableSliceFamily super.from,
    required ({FinampPlayable item, int startingOffset, int? limit})
    super.argument,
  }) : super(
         retry: null,
         name: r'getPlayableSliceProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getPlayableSliceHash();

  @override
  String toString() {
    return r'getPlayableSliceProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<PlayableSlice> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<PlayableSlice> create(Ref ref) {
    final argument =
        this.argument
            as ({FinampPlayable item, int startingOffset, int? limit});
    return getPlayableSlice(
      ref,
      item: argument.item,
      startingOffset: argument.startingOffset,
      limit: argument.limit,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GetPlayableSliceProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getPlayableSliceHash() => r'a7de6c8ea850e99401cdae69950743ea398e1370';

final class GetPlayableSliceFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<PlayableSlice>,
          ({FinampPlayable item, int startingOffset, int? limit})
        > {
  GetPlayableSliceFamily._()
    : super(
        retry: null,
        name: r'getPlayableSliceProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetPlayableSliceProvider call({
    required FinampPlayable item,
    required int startingOffset,
    int? limit,
  }) => GetPlayableSliceProvider._(
    argument: (item: item, startingOffset: startingOffset, limit: limit),
    from: this,
  );

  @override
  String toString() => r'getPlayableSliceProvider';
}

@ProviderFor(getAlbumShuffledPlayerSlice)
final getAlbumShuffledPlayerSliceProvider =
    GetAlbumShuffledPlayerSliceFamily._();

final class GetAlbumShuffledPlayerSliceProvider
    extends
        $FunctionalProvider<
          AsyncValue<PlayableSlice>,
          PlayableSlice,
          FutureOr<PlayableSlice>
        >
    with $FutureModifier<PlayableSlice>, $FutureProvider<PlayableSlice> {
  GetAlbumShuffledPlayerSliceProvider._({
    required GetAlbumShuffledPlayerSliceFamily super.from,
    required FinampPlayable super.argument,
  }) : super(
         retry: null,
         name: r'getAlbumShuffledPlayerSliceProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getAlbumShuffledPlayerSliceHash();

  @override
  String toString() {
    return r'getAlbumShuffledPlayerSliceProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<PlayableSlice> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<PlayableSlice> create(Ref ref) {
    final argument = this.argument as FinampPlayable;
    return getAlbumShuffledPlayerSlice(ref, item: argument);
  }

  @override
  bool operator ==(Object other) {
    return other is GetAlbumShuffledPlayerSliceProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getAlbumShuffledPlayerSliceHash() =>
    r'22806b9b8a8968151f5a4497c4c56a89e9021518';

final class GetAlbumShuffledPlayerSliceFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<PlayableSlice>, FinampPlayable> {
  GetAlbumShuffledPlayerSliceFamily._()
    : super(
        retry: null,
        name: r'getAlbumShuffledPlayerSliceProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetAlbumShuffledPlayerSliceProvider call({required FinampPlayable item}) =>
      GetAlbumShuffledPlayerSliceProvider._(argument: item, from: this);

  @override
  String toString() => r'getAlbumShuffledPlayerSliceProvider';
}

@ProviderFor(getChildTracks)
final getChildTracksProvider = GetChildTracksFamily._();

final class GetChildTracksProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Track>>,
          List<Track>,
          FutureOr<List<Track>>
        >
    with $FutureModifier<List<Track>>, $FutureProvider<List<Track>> {
  GetChildTracksProvider._({
    required GetChildTracksFamily super.from,
    required FinampUnpagedDisplayable<Track> super.argument,
  }) : super(
         retry: null,
         name: r'getChildTracksProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getChildTracksHash();

  @override
  String toString() {
    return r'getChildTracksProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<Track>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<Track>> create(Ref ref) {
    final argument = this.argument as FinampUnpagedDisplayable<Track>;
    return getChildTracks(ref, item: argument);
  }

  @override
  bool operator ==(Object other) {
    return other is GetChildTracksProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getChildTracksHash() => r'549f7a09f30ea42698768bf2b1243312485b70b6';

final class GetChildTracksFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<Track>>,
          FinampUnpagedDisplayable<Track>
        > {
  GetChildTracksFamily._()
    : super(
        retry: null,
        name: r'getChildTracksProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetChildTracksProvider call({
    required FinampUnpagedDisplayable<Track> item,
  }) => GetChildTracksProvider._(argument: item, from: this);

  @override
  String toString() => r'getChildTracksProvider';
}

@ProviderFor(getChildItems)
final getChildItemsProvider = GetChildItemsFamily._();

final class GetChildItemsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<FinampPlayableDto>>,
          List<FinampPlayableDto>,
          FutureOr<List<FinampPlayableDto>>
        >
    with
        $FutureModifier<List<FinampPlayableDto>>,
        $FutureProvider<List<FinampPlayableDto>> {
  GetChildItemsProvider._({
    required GetChildItemsFamily super.from,
    required FinampUnpagedDisplayable<FinampPlayableDto> super.argument,
  }) : super(
         retry: null,
         name: r'getChildItemsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getChildItemsHash();

  @override
  String toString() {
    return r'getChildItemsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<FinampPlayableDto>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<FinampPlayableDto>> create(Ref ref) {
    final argument =
        this.argument as FinampUnpagedDisplayable<FinampPlayableDto>;
    return getChildItems(ref, item: argument);
  }

  @override
  bool operator ==(Object other) {
    return other is GetChildItemsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getChildItemsHash() => r'9bb5a70df1d6eeb9407ba0e44729af2cce2a0dd2';

final class GetChildItemsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<FinampPlayableDto>>,
          FinampUnpagedDisplayable<FinampPlayableDto>
        > {
  GetChildItemsFamily._()
    : super(
        retry: null,
        name: r'getChildItemsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetChildItemsProvider call({
    required FinampUnpagedDisplayable<FinampPlayableDto> item,
  }) => GetChildItemsProvider._(argument: item, from: this);

  @override
  String toString() => r'getChildItemsProvider';
}

@ProviderFor(getChildren)
final getChildrenProvider = GetChildrenFamily._();

final class GetChildrenProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<FinampDisplayableOrPlayable>>,
          List<FinampDisplayableOrPlayable>,
          FutureOr<List<FinampDisplayableOrPlayable>>
        >
    with
        $FutureModifier<List<FinampDisplayableOrPlayable>>,
        $FutureProvider<List<FinampDisplayableOrPlayable>> {
  GetChildrenProvider._({
    required GetChildrenFamily super.from,
    required FinampUnpagedDisplayable<FinampDisplayableOrPlayable>
    super.argument,
  }) : super(
         retry: null,
         name: r'getChildrenProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getChildrenHash();

  @override
  String toString() {
    return r'getChildrenProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<FinampDisplayableOrPlayable>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<FinampDisplayableOrPlayable>> create(Ref ref) {
    final argument =
        this.argument as FinampUnpagedDisplayable<FinampDisplayableOrPlayable>;
    return getChildren(ref, item: argument);
  }

  @override
  bool operator ==(Object other) {
    return other is GetChildrenProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getChildrenHash() => r'd2ea3dcb7eda184998a67d1f5ba49780a08c72b1';

final class GetChildrenFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<FinampDisplayableOrPlayable>>,
          FinampUnpagedDisplayable<FinampDisplayableOrPlayable>
        > {
  GetChildrenFamily._()
    : super(
        retry: null,
        name: r'getChildrenProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetChildrenProvider call({
    required FinampUnpagedDisplayable<FinampDisplayableOrPlayable> item,
  }) => GetChildrenProvider._(argument: item, from: this);

  @override
  String toString() => r'getChildrenProvider';
}
