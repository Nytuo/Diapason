import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/connect/remote_playback.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_slices.dart';

/// This device's queue as Connect shares it: linear tracks, current index, shuffle order and Next Up.
ConnectQueue? localConnectQueue() {
  final player = GetIt.instance<MusicPlayerBackgroundTask>();
  final queue = GetIt.instance<QueueService>();

  final tags = player.audioSources
      .map((source) => (source as IndexedAudioSource).tag)
      .whereType<FinampQueueItem>()
      .toList();
  if (tags.isEmpty) return null;

  final items = <Map<String, dynamic>>[
    for (final tag in tags) (tag.item.extras!["itemJson"] as Map).cast<String, dynamic>(),
  ];
  final shuffled = queue.playbackOrder == FinampPlaybackOrder.shuffled && player.shuffleIndices.length == items.length;
  return ConnectQueue(
    items: items,
    index: player.sequenceState.currentIndex ?? 0,
    position: player.playbackPosition.inMilliseconds / 1000,
    shuffleOrder: shuffled ? List.of(player.shuffleIndices) : null,
    nextUpLength: queue.getQueue().nextUp.length,
    playing: !player.paused,
    repeat: queue.loopMode.name,
  );
}

/// The controlled side of Diapason Connect: reports what this device plays and does what a controller asks.
class ConnectPlayerBridge {
  ConnectPlayerBridge();

  static final _log = Logger("ConnectPlayerBridge");

  static final connectSource = QueueItemSource(
    type: QueueItemSourceType.unknown,
    name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Diapason Connect"),
    id: BaseItemId("diapason-connect"),
  );

  ConnectService get _connect => GetIt.instance<ConnectService>();
  QueueService get _queue => GetIt.instance<QueueService>();
  MusicPlayerBackgroundTask get _player => GetIt.instance<MusicPlayerBackgroundTask>();

  void attach() {
    _connect.localStatusProvider = _currentStatus;
    _connect.onCommand = _handleCommand;
    _connect.onPlayQueue = _handlePlayQueue;
    _connect.queueProvider = () => localConnectQueue() ?? const ConnectQueue(items: [], index: 0, position: 0);
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
    // A device that is itself controlling another one reports nothing of its own.
    if (RemotePlayback.current?.active ?? false) return ConnectStatus.stopped;

    final current = _queue.getQueue().currentTrack;
    final state = _player.playbackState.valueOrNull;

    if (current == null) return ConnectStatus.stopped;

    final queue = localConnectQueue();
    final item = current.baseItem;
    return ConnectStatus(
      song: ConnectSong(
        id: item.id.raw,
        title: item.name ?? "",
        artist: item.albumArtist ?? item.artists?.firstOrNull ?? "",
        album: item.album ?? "",
        duration: (item.runTimeTicksDuration()?.inMilliseconds ?? 0) / 1000,
      ),
      state: (state?.playing ?? false) ? "playing" : "paused",
      position: _player.playbackPosition.inMilliseconds / 1000,
      volume: _player.volume,
      queueVersion: queue?.version,
      queueIndex: queue?.index,
      shuffle: _queue.playbackOrder == FinampPlaybackOrder.shuffled,
      repeat: _queue.loopMode.name,
    );
  }

  Future<List<BaseItemDto>> _itemsFrom(Object? raw) async {
    final list = raw is List
        ? raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : <Map<String, dynamic>>[];
    return resolveConnectItems(list);
  }

  /// Track JSON from another device, as items. Full `BaseItemDto` JSON is used as is; a bare id (older devices) is
  /// looked up in our library.
  static Future<List<BaseItemDto>> resolveConnectItems(List<Map<String, dynamic>> raw) async {
    final aggregate = GetIt.instance<AggregateBackend>();
    final out = <BaseItemDto>[];
    for (final json in raw) {
      try {
        if (json["Name"] != null) {
          out.add(BaseItemDto.fromJson(json));
          continue;
        }
        final id = json["Id"] as String?;
        if (id == null || id.isEmpty) continue;
        final item = await aggregate.getItemById(BaseItemId(id));
        if (item != null) out.add(item);
      } catch (e) {
        _log.fine("Could not use a track sent over Connect: $e");
      }
    }
    return out;
  }

  Future<void> _handleCommand(ConnectCommand command) async {
    _log.fine("Connect command: ${command.action}");
    final args = command.args;
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
      case "skipBy":
        await _queue.skipByOffset((args["offset"] as num?)?.toInt() ?? 0);
      case "shuffle":
        await _queue.setPlaybackOrder(args["on"] == true ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear);
      case "repeat":
        final mode = FinampLoopMode.values.where((m) => m.name == args["mode"]).firstOrNull;
        if (mode != null) _queue.loopMode = mode;
      case "addNext" || "addToQueue" || "addToNextUp":
        final items = await _itemsFrom(args["items"]);
        if (items.isEmpty) return;
        final slice = PlayableSlice.simple(items, connectSource);
        await switch (command.action) {
          "addNext" => _queue.addNext(slice),
          "addToNextUp" => _queue.addToNextUp(slice),
          _ => _queue.addToQueue(slice),
        };
      case "removeAt":
        await _queue.removeAtOffset((args["offset"] as num?)?.toInt() ?? 0);
      case "reorder":
        await _queue.reorderByOffset((args["from"] as num?)?.toInt() ?? 0, (args["to"] as num?)?.toInt() ?? 0);
      case "clearNextUp":
        await _queue.clearNextUp();
      default:
        _log.fine("Ignoring unknown Connect command '${command.action}'");
    }
  }

  Future<void> _handlePlayQueue(ConnectQueue queue) async {
    final items = await resolveConnectItems(queue.items);
    if (items.isEmpty) {
      _log.warning("A queue was pushed to us, but none of its ${queue.items.length} track(s) exist on this device");
      return;
    }
    final complete = items.length == queue.items.length;

    await _queue.startMirroredPlayback(
      items: items,
      index: complete ? queue.index : 0,
      source: connectSource,
      shuffleOrder: complete ? queue.shuffleOrder : null,
      nextUpLength: complete ? queue.nextUpLength : 0,
      position: Duration(milliseconds: (queue.position * 1000).round()),
      loop: FinampLoopMode.values.where((m) => m.name == queue.repeat).firstOrNull,
      beginPlaying: queue.playing,
    );
    _log.info("Playing a queue of ${items.length} track(s) pushed over Connect");
  }
}
