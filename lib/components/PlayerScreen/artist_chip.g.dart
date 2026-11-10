// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: deprecated_member_use_from_same_package, strict_raw_type, unused_element, unused_local_variable

// dart format off

part of 'artist_chip.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(artistItem)
final artistItemProvider = ArtistItemFamily._();

final class ArtistItemProvider
    extends
        $FunctionalProvider<
          AsyncValue<BaseItemDto?>,
          BaseItemDto?,
          FutureOr<BaseItemDto?>
        >
    with $FutureModifier<BaseItemDto?>, $FutureProvider<BaseItemDto?> {
  ArtistItemProvider._({
    required ArtistItemFamily super.from,
    required BaseItemId super.argument,
  }) : super(
         retry: null,
         name: r'artistItemProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$artistItemHash();

  @override
  String toString() {
    return r'artistItemProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<BaseItemDto?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<BaseItemDto?> create(Ref ref) {
    final argument = this.argument as BaseItemId;
    return artistItem(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ArtistItemProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$artistItemHash() => r'e388637c1744efd637f06d56a32d7b4617f21124';

final class ArtistItemFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<BaseItemDto?>, BaseItemId> {
  ArtistItemFamily._()
    : super(
        retry: null,
        name: r'artistItemProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ArtistItemProvider call(BaseItemId id) =>
      ArtistItemProvider._(argument: id, from: this);

  @override
  String toString() => r'artistItemProvider';
}
