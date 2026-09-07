import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/jellyfin_backend.dart';
import 'package:diapason/services/backends/local_backend.dart';
import 'package:diapason/services/backends/mpd_backend.dart';
import 'package:diapason/services/backends/plex_backend.dart';
import 'package:diapason/services/backends/subsonic_backend.dart';
import 'package:diapason/services/backends/youtube_backend.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/tvos/appletv_audio_channel.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce/hive.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';

/// Isar has no tvOS native binary, so on tvOS this stores configs as JSON in
/// a "MediaSourceConfigs" Hive box (key: sourceId) instead of Isar.
class MediaSourceService {
  MediaSourceService();

  static final _log = Logger("MediaSourceService");

  static bool get _isTvOS => AppleTvAudioChannel.isSupported;

  final Isar? _isar = _isTvOS ? null : GetIt.instance<Isar>();
  BackendRegistry get _registry => GetIt.instance<BackendRegistry>();

  Box<String> get _tvOSSources => Hive.box<String>("MediaSourceConfigs");

  List<MediaSourceConfig> get sources => _isTvOS
      ? _tvOSSources.values
            .map((json) => MediaSourceConfig.fromTvOSStorageJson(jsonDecode(json) as Map<String, dynamic>))
            .toList()
      : _isar!.mediaSourceConfigs.where().findAllSync();

  void _put(MediaSourceConfig config) {
    if (_isTvOS) {
      _tvOSSources.put(config.sourceId, jsonEncode(config.toTvOSStorageJson()));
    } else {
      _isar!.writeTxnSync(() => _isar.mediaSourceConfigs.putSync(config));
    }
  }

  Future<void> loadSources() async {
    await _migrateLegacyJellyfinUser();

    for (final config in sources) {
      _registry.register(_build(config));
    }

    _registry.register(YouTubeBackend());

    _log.info("Loaded ${_registry.all.length} source(s).");
  }

  MediaBackend _build(MediaSourceConfig config) => switch (config.kind) {
    MediaSourceKind.jellyfin => JellyfinBackend(config),
    MediaSourceKind.subsonic => SubsonicBackend(config),
    MediaSourceKind.plex => PlexBackend(config),
    MediaSourceKind.local => LocalBackend(config),
    MediaSourceKind.mpd => MpdBackend(config),
    MediaSourceKind.youtube => YouTubeBackend(),
  };

  Future<void> addSource(MediaSourceConfig config) async {
    _put(config);
    _registry.register(_build(config));
  }

  String newSourceId(MediaSourceKind kind) =>
      MediaSourceConfig.newSourceId(kind, sources.map((s) => s.sourceId));

  Future<void> removeSource(String sourceId) async {
    await _registry.unregister(sourceId);
    if (_isTvOS) {
      _tvOSSources.delete(sourceId);
    } else {
      _isar!.writeTxnSync(() => _isar.mediaSourceConfigs.filter().sourceIdEqualTo(sourceId).deleteAllSync());
    }
  }

  Future<void> updateSource(MediaSourceConfig config) async {
    _put(config);
    await _registry.unregister(config.sourceId);
    _registry.register(_build(config));
  }

  Future<void> persistSourceState(MediaSourceConfig config) async {
    _put(config);
  }

  Future<bool> testConnection(MediaSourceConfig config) async {
    try {
      return await _build(config).ping();
    } catch (e) {
      _log.warning("Test connection failed for ${config.name}: $e");
      return false;
    }
  }

  Future<void> _migrateLegacyJellyfinUser() async {
    final user = GetIt.instance<FinampUserHelper>().currentUser;
    if (user == null) return;
    if (sources.any((s) => s.kind == MediaSourceKind.jellyfin)) {
      return;
    }

    final config = MediaSourceConfig(
      sourceId: MediaSourceConfig.newSourceId(MediaSourceKind.jellyfin, const []),
      kind: MediaSourceKind.jellyfin,
      name: Uri.tryParse(user.baseURL)?.host ?? "Jellyfin",
      publicAddress: user.publicAddress,
      localAddress: user.localAddress,
      preferLocalNetwork: user.preferLocalNetwork,
      isLocal: user.isLocal,
      accessToken: user.accessToken,
      userId: user.id,
    );
    _put(config);
    _log.info("Migrated the logged-in Jellyfin user into source ${config.sourceId}.");
  }

  Future<void> syncJellyfinSource() async {
    final user = GetIt.instance<FinampUserHelper>().currentUser;
    if (user == null) return;

    final existing = sources.where((s) => s.kind == MediaSourceKind.jellyfin).toList();
    if (existing.length > 1) return;

    final config =
        existing.singleOrNull ??
        MediaSourceConfig(
          sourceId: newSourceId(MediaSourceKind.jellyfin),
          kind: MediaSourceKind.jellyfin,
          name: "Jellyfin",
        );
    final isNew = existing.isEmpty;

    config
      ..name = Uri.tryParse(user.baseURL)?.host ?? config.name
      ..publicAddress = user.publicAddress
      ..localAddress = user.localAddress
      ..preferLocalNetwork = user.preferLocalNetwork
      ..isLocal = user.isLocal
      ..accessToken = user.accessToken
      ..userId = user.id;

    if (isNew) {
      await addSource(config);
      _log.info("Added Jellyfin source ${config.sourceId} from Sources settings.");
    } else {
      await updateSource(config);
      _log.info("Synced Jellyfin source ${config.sourceId} after reconnect.");
    }
  }
}
