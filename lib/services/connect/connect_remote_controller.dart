import 'dart:async';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// What another Diapason device is currently playing, expressed the same way
/// local playback is: the real library [BaseItemDto] where we can find it, so
/// the transport bar can show proper cover art and metadata rather than the
/// handful of strings the remote reports.
class RemoteNowPlaying {
  const RemoteNowPlaying({
    required this.device,
    required this.playing,
    required this.duration,
    required this.volume,
    this.item,
    this.song,
  });

  final ConnectDevice device;

  final BaseItemDto? item;

  final ConnectSong? song;

  final bool playing;
  final Duration duration;
  final double volume;

  bool get hasTrack => song != null;

  String get title => item?.name ?? song?.title ?? "Nothing playing";

  String get artist => item?.albumArtist ?? item?.artists?.firstOrNull ?? song?.artist ?? "";
}

class ConnectRemoteController {
  static final _log = Logger("ConnectRemoteController");

  static const _tick = Duration(milliseconds: 500);

  ConnectService get _connect => GetIt.instance<ConnectService>();

  final ValueNotifier<RemoteNowPlaying?> nowPlaying = ValueNotifier(null);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  final Map<String, BaseItemDto> _itemCache = {};

  final Set<String> _unresolvable = {};

  Timer? _ticker;
  String? _resolvingId;
  Duration _polledPosition = Duration.zero;
  DateTime _polledAt = DateTime.now();

  bool get isRemote => _connect.connectedDevice.value != null;

  String? get deviceName => _connect.connectedDevice.value?.name;

  void attach() {
    _connect.remoteStatus.addListener(_onStatus);
    _connect.connectedDevice.addListener(_onDevice);
    _ticker = Timer.periodic(_tick, (_) => _interpolate());
  }

  void dispose() {
    _ticker?.cancel();
    _connect.remoteStatus.removeListener(_onStatus);
    _connect.connectedDevice.removeListener(_onDevice);
  }

  void _onDevice() {
    if (_connect.connectedDevice.value == null) {
      nowPlaying.value = null;
      position.value = Duration.zero;
    }
  }

  void _onStatus() {
    final device = _connect.connectedDevice.value;
    final status = _connect.remoteStatus.value;
    if (device == null || status == null) {
      nowPlaying.value = null;
      return;
    }

    final song = status.song;
    _polledPosition = Duration(milliseconds: (status.position * 1000).round());
    _polledAt = DateTime.now();
    position.value = _polledPosition;

    nowPlaying.value = RemoteNowPlaying(
      device: device,
      item: song == null ? null : _itemCache[song.id],
      song: song,
      playing: status.isPlaying,
      duration: Duration(milliseconds: ((song?.duration ?? 0) * 1000).round()),
      volume: status.volume,
    );

    if (song != null && !_itemCache.containsKey(song.id) && !_unresolvable.contains(song.id)) {
      unawaited(_resolve(song.id));
    }
  }

  Future<void> _resolve(String id) async {
    if (_resolvingId == id) return;
    _resolvingId = id;
    try {
      final item = await GetIt.instance<AggregateBackend>().getItemById(BaseItemId(id));
      if (item == null) {
        _unresolvable.add(id);
      } else {
        _itemCache[id] = item;
        final current = nowPlaying.value;
        if (current?.song?.id == id) {
          nowPlaying.value = RemoteNowPlaying(
            device: current!.device,
            item: item,
            song: current.song,
            playing: current.playing,
            duration: current.duration,
            volume: current.volume,
          );
        }
      }
    } catch (e) {
      _unresolvable.add(id);
      _log.fine("Couldn't resolve remote track '$id' locally: $e");
    } finally {
      if (_resolvingId == id) _resolvingId = null;
    }
  }

  void _interpolate() {
    final current = nowPlaying.value;
    if (current == null || !current.playing) return;
    final elapsed = DateTime.now().difference(_polledAt);
    final next = _polledPosition + elapsed;
    position.value = current.duration > Duration.zero && next > current.duration ? current.duration : next;
  }

  Future<void> togglePlayback() async {
    final playing = nowPlaying.value?.playing ?? false;
    await _connect.sendCommand(playing ? "pause" : "play");
  }

  Future<void> next() => _connect.sendCommand("next");

  Future<void> previous() => _connect.sendCommand("previous");

  Future<void> seek(Duration to) async {
    _polledPosition = to;
    _polledAt = DateTime.now();
    position.value = to;
    await _connect.sendCommand("seek", position: to.inMilliseconds / 1000);
  }

  Future<void> setVolume(double volume) async {
    final current = nowPlaying.value;
    if (current != null) {
      nowPlaying.value = RemoteNowPlaying(
        device: current.device,
        item: current.item,
        song: current.song,
        playing: current.playing,
        duration: current.duration,
        volume: volume,
      );
    }
    await _connect.sendCommand("volume", volume: volume);
  }

  void disconnect() => _connect.disconnect();
}
