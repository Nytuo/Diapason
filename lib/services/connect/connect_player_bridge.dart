import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import 'package:diapason/models/jellyfin_models.dart';

class ConnectPlayerBridge {
  ConnectPlayerBridge();

  static final _log = Logger("ConnectPlayerBridge");

  ConnectService get _connect => GetIt.instance<ConnectService>();
  QueueService get _queue => GetIt.instance<QueueService>();
  MusicPlayerBackgroundTask get _player => GetIt.instance<MusicPlayerBackgroundTask>();

  void attach() {
    _connect.localStatusProvider = _currentStatus;
    _connect.onCommand = _handleCommand;
    _connect.onPlayQueue = _handlePlayQueue;
    _connect.libraryProvider = _libraryForCompanions;
  }

  static const _libraryLimit = 300;

  Future<List<Map<String, dynamic>>> _libraryForCompanions() async {
    final aggregate = GetIt.instance<AggregateBackend>();
    final registry = GetIt.instance<BackendRegistry>();

    final tracks = await aggregate.getItems(includeItemTypes: "Audio", limit: _libraryLimit);
    final out = <Map<String, dynamic>>[];

    for (final track in tracks) {
      final backend = registry.forItem(track);
      if (backend == null) continue;
      if (backend.config.kind == MediaSourceKind.local || backend.config.kind == MediaSourceKind.youtube) {
        continue;
      }

      try {
        final source = await backend.resolveStream(track, transcode: false);
        if (source.isLocalFile) continue;

        out.add({
          "id": track.id.raw,
          "title": track.name ?? "",
          "artist": track.albumArtist ?? track.artists?.firstOrNull ?? "",
          "album": track.album ?? "",
          "duration": (track.runTimeTicksDuration()?.inSeconds ?? 0),
          "streamUrl": source.uri.toString(),
          "art": backend.imageUrl(track, maxWidth: 200)?.toString(),
        });
      } catch (e) {
        _log.fine("Skipping '${track.name}' for a companion: $e");
      }
    }

    _log.info("Serving ${out.length} track(s) to a Connect companion");
    return out;
  }

  ConnectStatus _currentStatus() {
    final current = _queue.getQueue().currentTrack;
    final state = _player.playbackState.valueOrNull;

    if (current == null) return ConnectStatus.stopped;

    final item = current.baseItem;
    return ConnectStatus(
      song: item == null
          ? null
          : ConnectSong(
              id: item.id.raw,
              title: item.name ?? "",
              artist: item.albumArtist ?? item.artists?.firstOrNull ?? "",
              album: item.album ?? "",
              duration: (item.runTimeTicksDuration()?.inMilliseconds ?? 0) / 1000,
            ),
      state: (state?.playing ?? false) ? "playing" : "paused",
      position: (state?.position.inMilliseconds ?? 0) / 1000,
      volume: _player.volume,
    );
  }

  Future<void> _handleCommand(ConnectCommand command) async {
    _log.fine("Connect command: ${command.action}");
    switch (command.action) {
      case "play":
        await _player.play();
      case "pause":
        await _player.pause();
      case "next":
        await _player.skipToNext();
      case "previous":
        await _player.skipToPrevious();
      case "seek":
        if (command.position case final seconds?) {
          await _player.seek(Duration(milliseconds: (seconds * 1000).round()));
        }
      case "volume":
        if (command.volume case final volume?) {
          _player.setVolume(volume);
        }
      default:
        _log.fine("Ignoring unknown Connect command '${command.action}'");
    }
  }

  Future<void> _handlePlayQueue(List<Map<String, dynamic>> songs, int startIndex) async {
    final aggregate = GetIt.instance<AggregateBackend>();
    final resolved = <BaseItemDto>[];

    for (final song in songs) {
      final id = song["id"] as String?;
      if (id == null || id.isEmpty) continue;
      try {
        final item = await aggregate.getItemById(BaseItemId(id));
        if (item != null) resolved.add(item);
      } catch (e) {
        _log.fine("Could not resolve pushed track '$id': $e");
      }
    }

    if (resolved.isEmpty) {
      _log.warning("A queue was pushed to us, but none of its ${songs.length} track(s) exist on this device");
      return;
    }

    await _queue.startPlayback(
      items: resolved,
      startingIndex: startIndex.clamp(0, resolved.length - 1),
      source: QueueItemSource(
        type: QueueItemSourceType.unknown,
        name: const QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: "Diapason Connect",
        ),
        id: const BaseItemId("diapason-connect"),
      ),
    );
    _log.info("Playing a queue of ${resolved.length} track(s) pushed over Connect");
  }

  List<ConnectSong> currentQueueForCasting() {
    return _queue
        .getQueue()
        .nextUp
        .followedBy(_queue.getQueue().queue)
        .map((item) => item.baseItem)
        .nonNulls
        .map(
          (item) => ConnectSong(
            id: item.id.raw,
            title: item.name ?? "",
            artist: item.albumArtist ?? item.artists?.firstOrNull ?? "",
            album: item.album ?? "",
            duration: (item.runTimeTicksDuration()?.inMilliseconds ?? 0) / 1000,
          ),
        )
        .toList();
  }
}
