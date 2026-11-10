// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: deprecated_member_use_from_same_package, strict_raw_type, unused_element, unused_local_variable

// dart format off

part of 'artist_content_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(getArtistTracksSection)
final getArtistTracksSectionProvider = GetArtistTracksSectionFamily._();

final class GetArtistTracksSectionProvider
    extends
        $FunctionalProvider<
          AsyncValue<
            (
              List<BaseItemDto>,
              CuratedItemSelectionType,
              Set<CuratedItemSelectionType>?,
            )
          >,
          (
            List<BaseItemDto>,
            CuratedItemSelectionType,
            Set<CuratedItemSelectionType>?,
          ),
          FutureOr<
            (
              List<BaseItemDto>,
              CuratedItemSelectionType,
              Set<CuratedItemSelectionType>?,
            )
          >
        >
    with
        $FutureModifier<
          (
            List<BaseItemDto>,
            CuratedItemSelectionType,
            Set<CuratedItemSelectionType>?,
          )
        >,
        $FutureProvider<
          (
            List<BaseItemDto>,
            CuratedItemSelectionType,
            Set<CuratedItemSelectionType>?,
          )
        > {
  GetArtistTracksSectionProvider._({
    required GetArtistTracksSectionFamily super.from,
    required ({
      BaseItemDto artist,
      BaseItemDto? libraryFilter,
      BaseItemId? genreFilter,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'getArtistTracksSectionProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getArtistTracksSectionHash();

  @override
  String toString() {
    return r'getArtistTracksSectionProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<
    (
      List<BaseItemDto>,
      CuratedItemSelectionType,
      Set<CuratedItemSelectionType>?,
    )
  >
  $createElement($ProviderPointer pointer) => $FutureProviderElement(pointer);

  @override
  FutureOr<
    (
      List<BaseItemDto>,
      CuratedItemSelectionType,
      Set<CuratedItemSelectionType>?,
    )
  >
  create(Ref ref) {
    final argument =
        this.argument
            as ({
              BaseItemDto artist,
              BaseItemDto? libraryFilter,
              BaseItemId? genreFilter,
            });
    return getArtistTracksSection(
      ref,
      artist: argument.artist,
      libraryFilter: argument.libraryFilter,
      genreFilter: argument.genreFilter,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GetArtistTracksSectionProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getArtistTracksSectionHash() =>
    r'bfbabb095fbb3cdb65328aa1f05ad1549416e176';

final class GetArtistTracksSectionFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<
            (
              List<BaseItemDto>,
              CuratedItemSelectionType,
              Set<CuratedItemSelectionType>?,
            )
          >,
          ({
            BaseItemDto artist,
            BaseItemDto? libraryFilter,
            BaseItemId? genreFilter,
          })
        > {
  GetArtistTracksSectionFamily._()
    : super(
        retry: null,
        name: r'getArtistTracksSectionProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetArtistTracksSectionProvider call({
    required BaseItemDto artist,
    BaseItemDto? libraryFilter,
    BaseItemId? genreFilter,
  }) => GetArtistTracksSectionProvider._(
    argument: (
      artist: artist,
      libraryFilter: libraryFilter,
      genreFilter: genreFilter,
    ),
    from: this,
  );

  @override
  String toString() => r'getArtistTracksSectionProvider';
}

@ProviderFor(getArtistAlbums)
final getArtistAlbumsProvider = GetArtistAlbumsFamily._();

final class GetArtistAlbumsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<BaseItemDto>>,
          List<BaseItemDto>,
          FutureOr<List<BaseItemDto>>
        >
    with
        $FutureModifier<List<BaseItemDto>>,
        $FutureProvider<List<BaseItemDto>> {
  GetArtistAlbumsProvider._({
    required GetArtistAlbumsFamily super.from,
    required ({
      BaseItemDto artist,
      LibraryId? libraryFilter,
      BaseItemId? genreFilter,
      SortBy sortBy,
      SortOrder sortOrder,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'getArtistAlbumsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getArtistAlbumsHash();

  @override
  String toString() {
    return r'getArtistAlbumsProvider'
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
    final argument =
        this.argument
            as ({
              BaseItemDto artist,
              LibraryId? libraryFilter,
              BaseItemId? genreFilter,
              SortBy sortBy,
              SortOrder sortOrder,
            });
    return getArtistAlbums(
      ref,
      artist: argument.artist,
      libraryFilter: argument.libraryFilter,
      genreFilter: argument.genreFilter,
      sortBy: argument.sortBy,
      sortOrder: argument.sortOrder,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GetArtistAlbumsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getArtistAlbumsHash() => r'75e62bca55ec14d7e8ffcc77eea3bfbfb991baa6';

final class GetArtistAlbumsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<BaseItemDto>>,
          ({
            BaseItemDto artist,
            LibraryId? libraryFilter,
            BaseItemId? genreFilter,
            SortBy sortBy,
            SortOrder sortOrder,
          })
        > {
  GetArtistAlbumsFamily._()
    : super(
        retry: null,
        name: r'getArtistAlbumsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetArtistAlbumsProvider call({
    required BaseItemDto artist,
    LibraryId? libraryFilter,
    BaseItemId? genreFilter,
    SortBy sortBy = SortBy.premiereDate,
    SortOrder sortOrder = SortOrder.ascending,
  }) => GetArtistAlbumsProvider._(
    argument: (
      artist: artist,
      libraryFilter: libraryFilter,
      genreFilter: genreFilter,
      sortBy: sortBy,
      sortOrder: sortOrder,
    ),
    from: this,
  );

  @override
  String toString() => r'getArtistAlbumsProvider';
}

@ProviderFor(getPerformingArtistAlbums)
final getPerformingArtistAlbumsProvider = GetPerformingArtistAlbumsFamily._();

final class GetPerformingArtistAlbumsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<BaseItemDto>>,
          List<BaseItemDto>,
          FutureOr<List<BaseItemDto>>
        >
    with
        $FutureModifier<List<BaseItemDto>>,
        $FutureProvider<List<BaseItemDto>> {
  GetPerformingArtistAlbumsProvider._({
    required GetPerformingArtistAlbumsFamily super.from,
    required ({
      BaseItemDto artist,
      LibraryId? libraryFilter,
      BaseItemId? genreFilter,
      SortBy sortBy,
      SortOrder sortOrder,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'getPerformingArtistAlbumsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getPerformingArtistAlbumsHash();

  @override
  String toString() {
    return r'getPerformingArtistAlbumsProvider'
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
    final argument =
        this.argument
            as ({
              BaseItemDto artist,
              LibraryId? libraryFilter,
              BaseItemId? genreFilter,
              SortBy sortBy,
              SortOrder sortOrder,
            });
    return getPerformingArtistAlbums(
      ref,
      artist: argument.artist,
      libraryFilter: argument.libraryFilter,
      genreFilter: argument.genreFilter,
      sortBy: argument.sortBy,
      sortOrder: argument.sortOrder,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GetPerformingArtistAlbumsProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getPerformingArtistAlbumsHash() =>
    r'28283909ff342ba68f1fb327b2e90cbc5ef3037d';

final class GetPerformingArtistAlbumsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<BaseItemDto>>,
          ({
            BaseItemDto artist,
            LibraryId? libraryFilter,
            BaseItemId? genreFilter,
            SortBy sortBy,
            SortOrder sortOrder,
          })
        > {
  GetPerformingArtistAlbumsFamily._()
    : super(
        retry: null,
        name: r'getPerformingArtistAlbumsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetPerformingArtistAlbumsProvider call({
    required BaseItemDto artist,
    LibraryId? libraryFilter,
    BaseItemId? genreFilter,
    SortBy sortBy = SortBy.premiereDate,
    SortOrder sortOrder = SortOrder.ascending,
  }) => GetPerformingArtistAlbumsProvider._(
    argument: (
      artist: artist,
      libraryFilter: libraryFilter,
      genreFilter: genreFilter,
      sortBy: sortBy,
      sortOrder: sortOrder,
    ),
    from: this,
  );

  @override
  String toString() => r'getPerformingArtistAlbumsProvider';
}

@ProviderFor(getPerformingArtistTracks)
final getPerformingArtistTracksProvider = GetPerformingArtistTracksFamily._();

final class GetPerformingArtistTracksProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<BaseItemDto>>,
          List<BaseItemDto>,
          FutureOr<List<BaseItemDto>>
        >
    with
        $FutureModifier<List<BaseItemDto>>,
        $FutureProvider<List<BaseItemDto>> {
  GetPerformingArtistTracksProvider._({
    required GetPerformingArtistTracksFamily super.from,
    required ({
      BaseItemDto artist,
      LibraryId? libraryFilter,
      BaseItemId? genreFilter,
      bool onlyFavorites,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'getPerformingArtistTracksProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getPerformingArtistTracksHash();

  @override
  String toString() {
    return r'getPerformingArtistTracksProvider'
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
    final argument =
        this.argument
            as ({
              BaseItemDto artist,
              LibraryId? libraryFilter,
              BaseItemId? genreFilter,
              bool onlyFavorites,
            });
    return getPerformingArtistTracks(
      ref,
      artist: argument.artist,
      libraryFilter: argument.libraryFilter,
      genreFilter: argument.genreFilter,
      onlyFavorites: argument.onlyFavorites,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GetPerformingArtistTracksProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getPerformingArtistTracksHash() =>
    r'ce662b3539b9f715fae201e27a9de1d64b932fd4';

final class GetPerformingArtistTracksFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<BaseItemDto>>,
          ({
            BaseItemDto artist,
            LibraryId? libraryFilter,
            BaseItemId? genreFilter,
            bool onlyFavorites,
          })
        > {
  GetPerformingArtistTracksFamily._()
    : super(
        retry: null,
        name: r'getPerformingArtistTracksProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetPerformingArtistTracksProvider call({
    required BaseItemDto artist,
    LibraryId? libraryFilter,
    BaseItemId? genreFilter,
    bool onlyFavorites = false,
  }) => GetPerformingArtistTracksProvider._(
    argument: (
      artist: artist,
      libraryFilter: libraryFilter,
      genreFilter: genreFilter,
      onlyFavorites: onlyFavorites,
    ),
    from: this,
  );

  @override
  String toString() => r'getPerformingArtistTracksProvider';
}

@ProviderFor(getArtistTracks)
final getArtistTracksProvider = GetArtistTracksFamily._();

final class GetArtistTracksProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<BaseItemDto>>,
          List<BaseItemDto>,
          FutureOr<List<BaseItemDto>>
        >
    with
        $FutureModifier<List<BaseItemDto>>,
        $FutureProvider<List<BaseItemDto>> {
  GetArtistTracksProvider._({
    required GetArtistTracksFamily super.from,
    required ({
      BaseItemDto artist,
      LibraryId? libraryFilter,
      BaseItemId? genreFilter,
      bool onlyFavorites,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'getArtistTracksProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$getArtistTracksHash();

  @override
  String toString() {
    return r'getArtistTracksProvider'
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
    final argument =
        this.argument
            as ({
              BaseItemDto artist,
              LibraryId? libraryFilter,
              BaseItemId? genreFilter,
              bool onlyFavorites,
            });
    return getArtistTracks(
      ref,
      artist: argument.artist,
      libraryFilter: argument.libraryFilter,
      genreFilter: argument.genreFilter,
      onlyFavorites: argument.onlyFavorites,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GetArtistTracksProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$getArtistTracksHash() => r'4669bfd922bb15d4fee783f5e495b03337a43b38';

final class GetArtistTracksFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<BaseItemDto>>,
          ({
            BaseItemDto artist,
            LibraryId? libraryFilter,
            BaseItemId? genreFilter,
            bool onlyFavorites,
          })
        > {
  GetArtistTracksFamily._()
    : super(
        retry: null,
        name: r'getArtistTracksProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  GetArtistTracksProvider call({
    required BaseItemDto artist,
    LibraryId? libraryFilter,
    BaseItemId? genreFilter,
    bool onlyFavorites = false,
  }) => GetArtistTracksProvider._(
    argument: (
      artist: artist,
      libraryFilter: libraryFilter,
      genreFilter: genreFilter,
      onlyFavorites: onlyFavorites,
    ),
    from: this,
  );

  @override
  String toString() => r'getArtistTracksProvider';
}
