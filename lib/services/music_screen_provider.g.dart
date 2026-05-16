// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: deprecated_member_use_from_same_package, strict_raw_type

// dart format off


part of 'music_screen_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$loadHomeSectionItemsHash() =>
    r'24de9f6513fa6baf359f8993c0ec7c4118fdfd96';

/// Copied from Dart SDK
class _SystemHash {
  _SystemHash._();

  static int combine(int hash, int value) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + value);
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int finish(int hash) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    // ignore: parameter_assignments
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}

/// See also [loadHomeSectionItems].
@ProviderFor(loadHomeSectionItems)
const loadHomeSectionItemsProvider = LoadHomeSectionItemsFamily();

/// See also [loadHomeSectionItems].
class LoadHomeSectionItemsFamily
    extends Family<AsyncValue<List<BaseItemDto>?>> {
  /// See also [loadHomeSectionItems].
  const LoadHomeSectionItemsFamily();

  /// See also [loadHomeSectionItems].
  LoadHomeSectionItemsProvider call({
    required HomeScreenSectionConfiguration sectionInfo,
    required int startIndex,
    required int limit,
  }) {
    return LoadHomeSectionItemsProvider(
      sectionInfo: sectionInfo,
      startIndex: startIndex,
      limit: limit,
    );
  }

  @override
  LoadHomeSectionItemsProvider getProviderOverride(
    covariant LoadHomeSectionItemsProvider provider,
  ) {
    return call(
      sectionInfo: provider.sectionInfo,
      startIndex: provider.startIndex,
      limit: provider.limit,
    );
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'loadHomeSectionItemsProvider';
}

/// See also [loadHomeSectionItems].
class LoadHomeSectionItemsProvider extends FutureProvider<List<BaseItemDto>?> {
  /// See also [loadHomeSectionItems].
  LoadHomeSectionItemsProvider({
    required HomeScreenSectionConfiguration sectionInfo,
    required int startIndex,
    required int limit,
  }) : this._internal(
         (ref) => loadHomeSectionItems(
           ref as LoadHomeSectionItemsRef,
           sectionInfo: sectionInfo,
           startIndex: startIndex,
           limit: limit,
         ),
         from: loadHomeSectionItemsProvider,
         name: r'loadHomeSectionItemsProvider',
         debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
             ? null
             : _$loadHomeSectionItemsHash,
         dependencies: LoadHomeSectionItemsFamily._dependencies,
         allTransitiveDependencies:
             LoadHomeSectionItemsFamily._allTransitiveDependencies,
         sectionInfo: sectionInfo,
         startIndex: startIndex,
         limit: limit,
       );

  LoadHomeSectionItemsProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.sectionInfo,
    required this.startIndex,
    required this.limit,
  }) : super.internal();

  final HomeScreenSectionConfiguration sectionInfo;
  final int startIndex;
  final int limit;

  @override
  Override overrideWith(
    FutureOr<List<BaseItemDto>?> Function(LoadHomeSectionItemsRef provider)
    create,
  ) {
    return ProviderOverride(
      origin: this,
      override: LoadHomeSectionItemsProvider._internal(
        (ref) => create(ref as LoadHomeSectionItemsRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        sectionInfo: sectionInfo,
        startIndex: startIndex,
        limit: limit,
      ),
    );
  }

  @override
  FutureProviderElement<List<BaseItemDto>?> createElement() {
    return _LoadHomeSectionItemsProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is LoadHomeSectionItemsProvider &&
        other.sectionInfo == sectionInfo &&
        other.startIndex == startIndex &&
        other.limit == limit;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, sectionInfo.hashCode);
    hash = _SystemHash.combine(hash, startIndex.hashCode);
    hash = _SystemHash.combine(hash, limit.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin LoadHomeSectionItemsRef on FutureProviderRef<List<BaseItemDto>?> {
  /// The parameter `sectionInfo` of this provider.
  HomeScreenSectionConfiguration get sectionInfo;

  /// The parameter `startIndex` of this provider.
  int get startIndex;

  /// The parameter `limit` of this provider.
  int get limit;
}

class _LoadHomeSectionItemsProviderElement
    extends FutureProviderElement<List<BaseItemDto>?>
    with LoadHomeSectionItemsRef {
  _LoadHomeSectionItemsProviderElement(super.provider);

  @override
  HomeScreenSectionConfiguration get sectionInfo =>
      (origin as LoadHomeSectionItemsProvider).sectionInfo;
  @override
  int get startIndex => (origin as LoadHomeSectionItemsProvider).startIndex;
  @override
  int get limit => (origin as LoadHomeSectionItemsProvider).limit;
}

String _$globalSearchHash() => r'629baea3ff8943df78747a6e6804455125ae7136';

/// See also [globalSearch].
@ProviderFor(globalSearch)
const globalSearchProvider = GlobalSearchFamily();

/// See also [globalSearch].
class GlobalSearchFamily extends Family<AsyncValue<List<BaseItemDto>>> {
  /// See also [globalSearch].
  const GlobalSearchFamily();

  /// See also [globalSearch].
  GlobalSearchProvider call(String searchTerm, {required bool includeTracks}) {
    return GlobalSearchProvider(searchTerm, includeTracks: includeTracks);
  }

  @override
  GlobalSearchProvider getProviderOverride(
    covariant GlobalSearchProvider provider,
  ) {
    return call(provider.searchTerm, includeTracks: provider.includeTracks);
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'globalSearchProvider';
}

/// See also [globalSearch].
class GlobalSearchProvider
    extends AutoDisposeFutureProvider<List<BaseItemDto>> {
  /// See also [globalSearch].
  GlobalSearchProvider(String searchTerm, {required bool includeTracks})
    : this._internal(
        (ref) => globalSearch(
          ref as GlobalSearchRef,
          searchTerm,
          includeTracks: includeTracks,
        ),
        from: globalSearchProvider,
        name: r'globalSearchProvider',
        debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
            ? null
            : _$globalSearchHash,
        dependencies: GlobalSearchFamily._dependencies,
        allTransitiveDependencies:
            GlobalSearchFamily._allTransitiveDependencies,
        searchTerm: searchTerm,
        includeTracks: includeTracks,
      );

  GlobalSearchProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.searchTerm,
    required this.includeTracks,
  }) : super.internal();

  final String searchTerm;
  final bool includeTracks;

  @override
  Override overrideWith(
    FutureOr<List<BaseItemDto>> Function(GlobalSearchRef provider) create,
  ) {
    return ProviderOverride(
      origin: this,
      override: GlobalSearchProvider._internal(
        (ref) => create(ref as GlobalSearchRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        searchTerm: searchTerm,
        includeTracks: includeTracks,
      ),
    );
  }

  @override
  AutoDisposeFutureProviderElement<List<BaseItemDto>> createElement() {
    return _GlobalSearchProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is GlobalSearchProvider &&
        other.searchTerm == searchTerm &&
        other.includeTracks == includeTracks;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, searchTerm.hashCode);
    hash = _SystemHash.combine(hash, includeTracks.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin GlobalSearchRef on AutoDisposeFutureProviderRef<List<BaseItemDto>> {
  /// The parameter `searchTerm` of this provider.
  String get searchTerm;

  /// The parameter `includeTracks` of this provider.
  bool get includeTracks;
}

class _GlobalSearchProviderElement
    extends AutoDisposeFutureProviderElement<List<BaseItemDto>>
    with GlobalSearchRef {
  _GlobalSearchProviderElement(super.provider);

  @override
  String get searchTerm => (origin as GlobalSearchProvider).searchTerm;
  @override
  bool get includeTracks => (origin as GlobalSearchProvider).includeTracks;
}

String _$resolveSectionHash() => r'd61817efc0c34b2eea67198902b718bdcf14ed52';

/// See also [resolveSection].
@ProviderFor(resolveSection)
const resolveSectionProvider = ResolveSectionFamily();

/// See also [resolveSection].
class ResolveSectionFamily
    extends Family<AsyncValue<FinampDisplayable<FinampUnpagedPlayable>>> {
  /// See also [resolveSection].
  const ResolveSectionFamily();

  /// See also [resolveSection].
  ResolveSectionProvider call(HomeScreenSectionConfiguration section) {
    return ResolveSectionProvider(section);
  }

  @override
  ResolveSectionProvider getProviderOverride(
    covariant ResolveSectionProvider provider,
  ) {
    return call(provider.section);
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'resolveSectionProvider';
}

/// See also [resolveSection].
class ResolveSectionProvider
    extends
        AutoDisposeFutureProvider<FinampDisplayable<FinampUnpagedPlayable>> {
  /// See also [resolveSection].
  ResolveSectionProvider(HomeScreenSectionConfiguration section)
    : this._internal(
        (ref) => resolveSection(ref as ResolveSectionRef, section),
        from: resolveSectionProvider,
        name: r'resolveSectionProvider',
        debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
            ? null
            : _$resolveSectionHash,
        dependencies: ResolveSectionFamily._dependencies,
        allTransitiveDependencies:
            ResolveSectionFamily._allTransitiveDependencies,
        section: section,
      );

  ResolveSectionProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.section,
  }) : super.internal();

  final HomeScreenSectionConfiguration section;

  @override
  Override overrideWith(
    FutureOr<FinampDisplayable<FinampUnpagedPlayable>> Function(
      ResolveSectionRef provider,
    )
    create,
  ) {
    return ProviderOverride(
      origin: this,
      override: ResolveSectionProvider._internal(
        (ref) => create(ref as ResolveSectionRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        section: section,
      ),
    );
  }

  @override
  AutoDisposeFutureProviderElement<FinampDisplayable<FinampUnpagedPlayable>>
  createElement() {
    return _ResolveSectionProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is ResolveSectionProvider && other.section == section;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, section.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin ResolveSectionRef
    on AutoDisposeFutureProviderRef<FinampDisplayable<FinampUnpagedPlayable>> {
  /// The parameter `section` of this provider.
  HomeScreenSectionConfiguration get section;
}

class _ResolveSectionProviderElement
    extends
        AutoDisposeFutureProviderElement<
          FinampDisplayable<FinampUnpagedPlayable>
        >
    with ResolveSectionRef {
  _ResolveSectionProviderElement(super.provider);

  @override
  HomeScreenSectionConfiguration get section =>
      (origin as ResolveSectionProvider).section;
}

String _$pagedContentHash() => r'9418d48d798668070a04d576da6155a95d2afc6e';

abstract class _$PagedContent
    extends
        BuildlessAutoDisposeNotifier<PagingState<int, FinampUnpagedPlayable>> {
  late final FinampDisplayable<FinampUnpagedPlayable> request;

  PagingState<int, FinampUnpagedPlayable> build(
    FinampDisplayable<FinampUnpagedPlayable> request,
  );
}

/// See also [PagedContent].
@ProviderFor(PagedContent)
const pagedContentProvider = PagedContentFamily();

/// See also [PagedContent].
class PagedContentFamily
    extends Family<PagingState<int, FinampUnpagedPlayable>> {
  /// See also [PagedContent].
  const PagedContentFamily();

  /// See also [PagedContent].
  PagedContentProvider call(FinampDisplayable<FinampUnpagedPlayable> request) {
    return PagedContentProvider(request);
  }

  @override
  PagedContentProvider getProviderOverride(
    covariant PagedContentProvider provider,
  ) {
    return call(provider.request);
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'pagedContentProvider';
}

/// See also [PagedContent].
class PagedContentProvider
    extends
        AutoDisposeNotifierProviderImpl<
          PagedContent,
          PagingState<int, FinampUnpagedPlayable>
        > {
  /// See also [PagedContent].
  PagedContentProvider(FinampDisplayable<FinampUnpagedPlayable> request)
    : this._internal(
        () => PagedContent()..request = request,
        from: pagedContentProvider,
        name: r'pagedContentProvider',
        debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
            ? null
            : _$pagedContentHash,
        dependencies: PagedContentFamily._dependencies,
        allTransitiveDependencies:
            PagedContentFamily._allTransitiveDependencies,
        request: request,
      );

  PagedContentProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.request,
  }) : super.internal();

  final FinampDisplayable<FinampUnpagedPlayable> request;

  @override
  PagingState<int, FinampUnpagedPlayable> runNotifierBuild(
    covariant PagedContent notifier,
  ) {
    return notifier.build(request);
  }

  @override
  Override overrideWith(PagedContent Function() create) {
    return ProviderOverride(
      origin: this,
      override: PagedContentProvider._internal(
        () => create()..request = request,
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        request: request,
      ),
    );
  }

  @override
  AutoDisposeNotifierProviderElement<
    PagedContent,
    PagingState<int, FinampUnpagedPlayable>
  >
  createElement() {
    return _PagedContentProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is PagedContentProvider && other.request == request;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, request.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin PagedContentRef
    on AutoDisposeNotifierProviderRef<PagingState<int, FinampUnpagedPlayable>> {
  /// The parameter `request` of this provider.
  FinampDisplayable<FinampUnpagedPlayable> get request;
}

class _PagedContentProviderElement
    extends
        AutoDisposeNotifierProviderElement<
          PagedContent,
          PagingState<int, FinampUnpagedPlayable>
        >
    with PagedContentRef {
  _PagedContentProviderElement(super.provider);

  @override
  FinampDisplayable<FinampUnpagedPlayable> get request =>
      (origin as PagedContentProvider).request;
}

// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
