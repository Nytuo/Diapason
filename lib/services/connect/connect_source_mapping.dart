import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _log = Logger("ConnectSourceMapping");

const _hintKey = "_DiapasonSource";

BackendRegistry? get _registry =>
    GetIt.instance.isRegistered<BackendRegistry>() ? GetIt.instance<BackendRegistry>() : null;

List<Map<String, dynamic>> withConnectSourceHints(List<Map<String, dynamic>> items) {
  final registry = _registry;
  if (registry == null) return items;
  return [
    for (final item in items)
      if (_sourceIdOf(item) case final sourceId? when registry.bySourceId(sourceId) != null)
        {...item, _hintKey: _describe(registry.bySourceId(sourceId)!.config)}
      else
        item,
  ];
}

List<Map<String, dynamic>> remapConnectItems(List<Map<String, dynamic>> items) {
  final registry = _registry;
  final mapping = <String, String?>{};
  return [
    for (final item in items)
      () {
        final hint = item[_hintKey];
        final clean = Map<String, dynamic>.of(item)..remove(_hintKey);
        final sourceId = _sourceIdOf(clean);
        if (registry == null || sourceId == null || registry.bySourceId(sourceId) != null) return clean;
        final local = mapping.putIfAbsent(
          sourceId,
          () => _matchLocalSource(registry, sourceId, hint is Map ? hint.cast<String, dynamic>() : null),
        );
        if (local == null) return clean;
        return _rewrite(clean, "$sourceId${BaseItemId.sourceSeparator}", "$local${BaseItemId.sourceSeparator}")!
            as Map<String, dynamic>;
      }(),
  ];
}

String? _sourceIdOf(Map<String, dynamic> item) {
  final id = item["Id"];
  if (id is! String || !id.contains(BaseItemId.sourceSeparator)) return null;
  final sourceId = BaseItemId(id).sourceId;
  return sourceId.isEmpty ? null : sourceId;
}

Map<String, String> _describe(MediaSourceConfig config) => {
  "kind": config.kind.name,
  "address": config.publicAddress,
  "localAddress": config.localAddress,
  "username": config.username,
  "userId": config.userId,
};

String _normalizeAddress(String? address) {
  var a = (address ?? "").trim().toLowerCase();
  while (a.endsWith("/")) {
    a = a.substring(0, a.length - 1);
  }
  return a;
}

String? _matchLocalSource(BackendRegistry registry, String foreignId, Map<String, dynamic>? hint) {
  final kind = hint != null
      ? MediaSourceKind.values.where((k) => k.name == hint["kind"]).firstOrNull
      : MediaSourceKind.values.where((k) => foreignId.startsWith("${k.idPrefix}-")).firstOrNull;
  if (kind == null) return null;
  final candidates = registry.configured.map((b) => b.config).where((c) => c.kind == kind).toList();

  MediaSourceConfig? match;
  if (hint != null) {
    final userId = (hint["userId"] as String?) ?? "";
    final username = ((hint["username"] as String?) ?? "").toLowerCase();
    final addresses = {
      _normalizeAddress(hint["address"] as String?),
      _normalizeAddress(hint["localAddress"] as String?),
    }..remove("");
    bool sameServer(MediaSourceConfig c) =>
        addresses.contains(_normalizeAddress(c.publicAddress)) || addresses.contains(_normalizeAddress(c.localAddress));
    match =
        candidates.where((c) => sameServer(c) && userId.isNotEmpty && c.userId == userId).firstOrNull ??
        candidates.where((c) => sameServer(c) && c.username.toLowerCase() == username).firstOrNull ??
        candidates.where(sameServer).singleOrNull;
  }
  match ??= candidates.singleOrNull;

  if (match == null) {
    _log.warning("Tracks from source '$foreignId' on another device match none of this device's ${kind.name} sources");
  } else {
    _log.info("Tracks from source '$foreignId' on another device play from '${match.sourceId}' here");
  }
  return match?.sourceId;
}

Object? _rewrite(Object? value, String from, String to) => switch (value) {
  String s when s.startsWith(from) => to + s.substring(from.length),
  Map<Object?, Object?> m => <String, dynamic>{for (final e in m.entries) "${e.key}": _rewrite(e.value, from, to)},
  List<Object?> l => [for (final e in l) _rewrite(e, from, to)],
  _ => value,
};
