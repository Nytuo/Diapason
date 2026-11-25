import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:logging/logging.dart';

final _log = Logger("WatchSetup");

/// The accounts of an [offer] a watch does not have yet, ready to add. A watch has no profiles: it takes every
/// account it is sent, and skips one it already has for the same server and user (or a malformed one).
List<MediaSourceConfig> newSourcesFromOffer(
  SourceOffer offer, {
  required List<MediaSourceConfig> existing,
  required String Function(MediaSourceKind kind, Iterable<String> taken) newId,
}) {
  final out = <MediaSourceConfig>[];
  bool known(MediaSourceConfig c) => [
    ...existing,
    ...out,
  ].any((s) => s.kind == c.kind && s.publicAddress == c.publicAddress && s.username == c.username);
  for (final json in offer.sources) {
    final MediaSourceConfig incoming;
    try {
      incoming = MediaSourceConfig.fromTvOSStorageJson(json);
    } catch (e) {
      _log.warning("Ignored a malformed account from ${offer.from}: $e");
      continue;
    }
    if (!incoming.kind.isConfigurable || incoming.kind == MediaSourceKind.local || known(incoming)) continue;
    out.add(
      MediaSourceConfig(
        sourceId: newId(incoming.kind, [...existing, ...out].map((s) => s.sourceId)),
        kind: incoming.kind,
        name: incoming.name,
        publicAddress: incoming.publicAddress,
        localAddress: incoming.localAddress,
        preferLocalNetwork: incoming.preferLocalNetwork,
        isLocal: incoming.isLocal,
        accessToken: incoming.accessToken,
        username: incoming.username,
        password: incoming.password,
        userId: incoming.userId,
      ),
    );
  }
  return out;
}
