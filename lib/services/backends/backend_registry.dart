import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:logging/logging.dart';

class BackendRegistry {
  static final _log = Logger("BackendRegistry");

  final Map<String, MediaBackend> _backends = {};

  Iterable<MediaBackend> get all => _backends.values;

  Iterable<MediaBackend> get enabled =>
      _backends.values.where((b) => b.config.enabled && b.config.kind.isConfigurable);

  Iterable<MediaBackend> get configured => _backends.values.where((b) => b.config.kind.isConfigurable);

  bool get isEmpty => configured.isEmpty;

  void register(MediaBackend backend) {
    _backends[backend.sourceId] = backend;
    _log.info("Registered backend ${backend.config}");
  }

  Future<void> unregister(String sourceId) async {
    final backend = _backends.remove(sourceId);
    if (backend != null) {
      await backend.logout();
      _log.info("Unregistered backend $sourceId");
    }
  }

  MediaBackend? bySourceId(String sourceId) => _backends[sourceId];

  MediaBackend? forItemId(BaseItemId id) {
    final sourceId = id.sourceId;
    if (sourceId.isEmpty) return _forUnscopedId(id);

    final backend = _backends[sourceId];
    if (backend == null) {
      _log.warning("No backend registered for source '$sourceId' (item ${id.raw}).");
    }
    return backend;
  }

  MediaBackend? _forUnscopedId(BaseItemId id) {
    final jellyfin = ofKind(MediaSourceKind.jellyfin).toList();
    if (jellyfin.length == 1) return jellyfin.single;

    if (jellyfin.isEmpty) {
      if (_backends.length == 1) return _backends.values.first;
      _log.warning("Unscoped item id '${id.raw}' and no Jellyfin source; cannot route it.");
      return null;
    }
    _log.warning(
      "Unscoped item id '${id.raw}' with ${jellyfin.length} Jellyfin sources: ambiguous. "
      "Jellyfin ids must be scoped before a second Jellyfin server can be added.",
    );
    return null;
  }

  MediaBackend? forItem(BaseItemDto item) => forItemId(item.id);

  MediaBackend backendFor(BaseItemDto item) {
    final backend = forItem(item);
    if (backend == null) {
      throw StateError("No source is registered for item '${item.id.raw}' (source '${item.id.sourceId}').");
    }
    return backend;
  }

  Iterable<MediaBackend> ofKind(MediaSourceKind kind) => _backends.values.where((b) => b.config.kind == kind);
}
