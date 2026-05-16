// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: deprecated_member_use_from_same_package, strict_raw_type

// dart format off


part of 'music_models.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$getPlayerSliceHash() => r'f80aeb31194a8139ffd01518f23e91947fd535ac';

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

/// See also [getPlayerSlice].
@ProviderFor(getPlayerSlice)
const getPlayerSliceProvider = GetPlayerSliceFamily();

/// See also [getPlayerSlice].
class GetPlayerSliceFamily extends Family<AsyncValue<PlayableSlice>> {
  /// See also [getPlayerSlice].
  const GetPlayerSliceFamily();

  /// See also [getPlayerSlice].
  GetPlayerSliceProvider call({
    required FinampPlayable item,
    required int startingOffset,
    int? limit,
  }) {
    return GetPlayerSliceProvider(
      item: item,
      startingOffset: startingOffset,
      limit: limit,
    );
  }

  @override
  GetPlayerSliceProvider getProviderOverride(
    covariant GetPlayerSliceProvider provider,
  ) {
    return call(
      item: provider.item,
      startingOffset: provider.startingOffset,
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
  String? get name => r'getPlayerSliceProvider';
}

/// See also [getPlayerSlice].
class GetPlayerSliceProvider extends AutoDisposeFutureProvider<PlayableSlice> {
  /// See also [getPlayerSlice].
  GetPlayerSliceProvider({
    required FinampPlayable item,
    required int startingOffset,
    int? limit,
  }) : this._internal(
         (ref) => getPlayerSlice(
           ref as GetPlayerSliceRef,
           item: item,
           startingOffset: startingOffset,
           limit: limit,
         ),
         from: getPlayerSliceProvider,
         name: r'getPlayerSliceProvider',
         debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
             ? null
             : _$getPlayerSliceHash,
         dependencies: GetPlayerSliceFamily._dependencies,
         allTransitiveDependencies:
             GetPlayerSliceFamily._allTransitiveDependencies,
         item: item,
         startingOffset: startingOffset,
         limit: limit,
       );

  GetPlayerSliceProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.item,
    required this.startingOffset,
    required this.limit,
  }) : super.internal();

  final FinampPlayable item;
  final int startingOffset;
  final int? limit;

  @override
  Override overrideWith(
    FutureOr<PlayableSlice> Function(GetPlayerSliceRef provider) create,
  ) {
    return ProviderOverride(
      origin: this,
      override: GetPlayerSliceProvider._internal(
        (ref) => create(ref as GetPlayerSliceRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        item: item,
        startingOffset: startingOffset,
        limit: limit,
      ),
    );
  }

  @override
  AutoDisposeFutureProviderElement<PlayableSlice> createElement() {
    return _GetPlayerSliceProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is GetPlayerSliceProvider &&
        other.item == item &&
        other.startingOffset == startingOffset &&
        other.limit == limit;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, item.hashCode);
    hash = _SystemHash.combine(hash, startingOffset.hashCode);
    hash = _SystemHash.combine(hash, limit.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin GetPlayerSliceRef on AutoDisposeFutureProviderRef<PlayableSlice> {
  /// The parameter `item` of this provider.
  FinampPlayable get item;

  /// The parameter `startingOffset` of this provider.
  int get startingOffset;

  /// The parameter `limit` of this provider.
  int? get limit;
}

class _GetPlayerSliceProviderElement
    extends AutoDisposeFutureProviderElement<PlayableSlice>
    with GetPlayerSliceRef {
  _GetPlayerSliceProviderElement(super.provider);

  @override
  FinampPlayable get item => (origin as GetPlayerSliceProvider).item;
  @override
  int get startingOffset => (origin as GetPlayerSliceProvider).startingOffset;
  @override
  int? get limit => (origin as GetPlayerSliceProvider).limit;
}

// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
