import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/connect/connect_source_mapping.dart';
import 'package:diapason/services/item_by_id_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// `diapason://show/<id>` links for sharing an album, track, artist or playlist.
///
/// Item ids carry the id of the source they come from, and that id is different on every device. So a link also
/// names the item, its type and artist: the device that opens it looks the id up, then the same item on its own
/// source of that kind, and finally searches its library by name. The link deliberately holds no server address or
/// account, since it's meant to be passed to other people.
class ShareLinks {
  ShareLinks._();

  static final _log = Logger("ShareLinks");

  static const scheme = "diapason";

  static Uri linkFor(BaseItemDto item) => Uri(
    scheme: scheme,
    host: "show",
    pathSegments: [item.id.raw],
    queryParameters: {
      if (item.type != null) "t": item.type!,
      if (item.name?.isNotEmpty ?? false) "n": item.name!,
      if (artistOf(item) case final artist?) "a": artist,
    },
  );

  static String? artistOf(BaseItemDto item) {
    final artist = item.albumArtist ?? item.artists?.firstOrNull;
    return (artist == null || artist.isEmpty || item.type == "MusicArtist") ? null : artist;
  }

  /// What goes in the share sheet: a readable line, then the link.
  static String shareText(BaseItemDto item) {
    final name = item.name ?? "Something";
    final artist = artistOf(item);
    return "${artist == null ? name : "$name — $artist"} on Diapason\n${linkFor(item)}";
  }

  /// The item a link points to on this device, or null if it can't be found here.
  static Future<BaseItemDto?> resolve(Uri uri, {ProviderContainer? container}) async {
    final segments = uri.pathSegments;
    if (segments.length != 1 || segments.single.isEmpty) return null;
    final providers = container ?? GetIt.instance<ProviderContainer>();
    final id = BaseItemId(segments.single);

    final direct = await _lookup(providers, id);
    if (direct != null) return direct;

    // Same item, but from this device's source of that kind (the source ids differ between devices).
    if (id.sourceId.isNotEmpty) {
      final local = localSourceIdForForeign(id.sourceId);
      if (local != null && local != id.sourceId) {
        final mapped = await _lookup(providers, BaseItemId.scoped(local, id.nativeId));
        if (mapped != null) return mapped;
      }
    }

    return _search(uri.queryParameters["n"], uri.queryParameters["t"], uri.queryParameters["a"]);
  }

  static Future<BaseItemDto?> _lookup(ProviderContainer providers, BaseItemId id) async {
    try {
      return await providers.read(itemByIdProvider(id).future);
    } catch (e) {
      _log.fine("No item $id here: $e");
      return null;
    }
  }

  static String _norm(String? s) => (s ?? "").trim().toLowerCase();

  static Future<BaseItemDto?> _search(String? name, String? type, String? artist) async {
    if (name == null || name.trim().isEmpty || !GetIt.instance.isRegistered<AggregateBackend>()) return null;
    try {
      final results = await GetIt.instance<AggregateBackend>().getItems(
        includeItemTypes: type,
        searchTerm: name.trim(),
        limit: 25,
      );
      final sameName = results.where((item) => _norm(item.name) == _norm(name)).toList();
      if (artist != null && artist.isNotEmpty) {
        final sameArtist = sameName.where(
          (item) =>
              _norm(item.albumArtist) == _norm(artist) || (item.artists ?? const []).any((a) => _norm(a) == _norm(artist)),
        );
        if (sameArtist.isNotEmpty) return sameArtist.first;
      }
      return sameName.firstOrNull;
    } catch (e) {
      _log.warning("Searching for a shared item failed: $e");
      return null;
    }
  }
}
