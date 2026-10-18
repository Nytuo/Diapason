import 'dart:async';

import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/connect/connect_source_mapping.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_player_bridge.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/connect/remote_playback.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// The controlling side of Diapason Connect, made to work like Spotify Connect.
///
/// Pick a device and playback moves there: the queue, track and position are sent over, and this device goes quiet.
/// From then on the whole app is a remote: the local queue mirrors the device's queue (kept in sync whenever it
/// changes), the player shows the device's state, and every play, pause, skip, seek, volume change and queue edit
/// made anywhere in the app is sent to the device (see [RemotePlayback] for how the player and queue forward).
/// Picking "This device" brings playback back, where it was.
class ConnectRemoteController implements RemotePlayback {
  static final _log = Logger("ConnectRemoteController");

  ConnectService get _connect => GetIt.instance<ConnectService>();
  QueueService get _queue => GetIt.instance<QueueService>();
  MusicPlayerBackgroundTask get _player => GetIt.instance<MusicPlayerBackgroundTask>();

  /// The device playback is on; null while it is on this one.
  ValueListenable<ConnectDevice?> get device => _connect.connectedDevice;

  /// Set while playback is moving to (or back from) a device, so the picker can show it.
  final ValueNotifier<bool> transferring = ValueNotifier(false);

  bool _syncing = false;
  bool _resyncWanted = false;
  bool _suspendMirror = false;
  String? _mirroredVersion;
  String? _legacySongId;

  bool _playing = false;
  Duration _position = Duration.zero;
  DateTime _positionAt = DateTime.now();
  double _volume = 1.0;

  @override
  bool get active => _connect.connectedDevice.value != null;

  @override
  bool get forwarding => active && !_syncing;

  @override
  bool get playing => _playing;

  @override
  Duration get position => _playing ? _position + DateTime.now().difference(_positionAt) : _position;

  @override
  double get volume => _volume;

  @override
  String? get deviceName => _connect.connectedDevice.value?.name;

  bool get isRemote => active;

  void attach() {
    RemotePlayback.current = this;
    _connect.remoteStatus.addListener(_onStatus);
    _connect.connectedDevice.addListener(_onDevice);
    _connect.onConnectionLost = (device) {
      GlobalSnackbar.message((_) => "Lost connection to ${device.name}. Playback stays there.");
    };
  }

  void dispose() {
    _connect.remoteStatus.removeListener(_onStatus);
    _connect.connectedDevice.removeListener(_onDevice);
    if (identical(RemotePlayback.current, this)) RemotePlayback.current = null;
  }

  // ---------------------------------------------------------------------------
  // Moving playback
  // ---------------------------------------------------------------------------

  /// Moves playback to [target]. False when it cannot be reached.
  Future<bool> transferTo(ConnectDevice target) async {
    if (_connect.connectedDevice.value == target) return true;
    transferring.value = true;
    _suspendMirror = true;
    try {
      // What is playing now, wherever that is, follows us to the new device.
      ConnectQueue? handover;
      if (active) {
        handover = await _connect.fetchQueue();
        await _connect.sendCommand("pause");
        _connect.disconnect();
      } else {
        handover = localConnectQueue();
        await _player.pause(disableFade: true);
      }

      final ok = await _connect.connect(target);
      if (!ok) {
        GlobalSnackbar.message((_) => "Couldn't reach ${target.name}. Is Diapason open on it?");
        return false;
      }
      if (handover != null && !handover.isEmpty) {
        await _connect.playQueue(handover);
      }
      _log.info("Playback moved to ${target.name}");
      return true;
    } finally {
      _suspendMirror = false;
      transferring.value = false;
      _onStatus();
    }
  }

  /// Brings playback back to this device, at the track and position the controlled device was at.
  Future<void> transferHere() async {
    if (!active) return;
    transferring.value = true;
    try {
      _suspendMirror = true;
      final queue = await _connect.fetchQueue();
      final wasPlaying = _connect.remoteStatus.value?.isPlaying ?? false;
      await _connect.sendCommand("pause");
      _connect.disconnect();

      if (queue != null && !queue.isEmpty) {
        await _loadQueue(queue, beginPlaying: wasPlaying, position: queue.position);
      } else if (wasPlaying) {
        await _player.play();
      }
      _log.info("Playback moved back to this device");
    } finally {
      _suspendMirror = false;
      transferring.value = false;
    }
  }

  /// Stops controlling the device but leaves its playback alone.
  void disconnect() => _connect.disconnect();

  // ---------------------------------------------------------------------------
  // Mirroring
  // ---------------------------------------------------------------------------

  void _onDevice() {
    if (_connect.connectedDevice.value == null) {
      _mirroredVersion = null;
      _legacySongId = null;
      _playing = false;
      _player.refreshRemoteState();
    }
  }

  void _onStatus() {
    final status = _connect.remoteStatus.value;
    if (status == null || !active) return;

    _playing = status.isPlaying;
    _position = Duration(milliseconds: (status.position * 1000).round());
    _positionAt = DateTime.now();
    _volume = status.volume;

    if (!_suspendMirror && !_syncing) {
      final version = status.queueVersion;
      if (version == null) {
        // A device from before queue mirroring: show at least what it plays.
        final songId = status.song?.id;
        if (songId != null && songId != _legacySongId) {
          _legacySongId = songId;
          unawaited(
            _mirror(
              () async => ConnectQueue(
                items: [
                  {"Id": songId},
                ],
                index: 0,
                position: status.position,
              ),
            ),
          );
        }
      } else if (version != _mirroredVersion) {
        unawaited(_mirror(_connect.fetchQueue));
      } else if (status.queueIndex case final index? when index != _player.sequenceState.currentIndex) {
        // Same queue, the device just moved on.
        unawaited(_player.mirrorToLinearIndex(index, _position));
      }
    }

    _player.refreshRemoteState();
  }

  Future<void> _mirror(Future<ConnectQueue?> Function() fetch) async {
    if (_syncing) {
      _resyncWanted = true;
      return;
    }
    _syncing = true;
    try {
      final queue = await fetch();
      if (queue == null || !active) return;
      if (queue.isEmpty) {
        _mirroredVersion = queue.version;
        return;
      }
      if (queue.version != localConnectQueue()?.version) {
        await _loadQueue(queue, beginPlaying: false, position: position.inMilliseconds / 1000);
      }
      _mirroredVersion = queue.version;
    } catch (e, stack) {
      _log.warning("Could not mirror the queue of $deviceName", e, stack);
    } finally {
      _syncing = false;
      _player.refreshRemoteState();
      if (_resyncWanted) {
        _resyncWanted = false;
        _onStatus();
      }
    }
  }

  Future<void> _loadQueue(ConnectQueue queue, {required bool beginPlaying, required double position}) async {
    final items = await ConnectPlayerBridge.resolveConnectItems(queue.items);
    if (items.isEmpty) return;
    final complete = items.length == queue.items.length;

    await _queue.startMirroredPlayback(
      items: items,
      index: complete ? queue.index : 0,
      source: QueueItemSource(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: active ? "Playing on $deviceName" : "Diapason Connect",
        ),
        id: const BaseItemId("diapason-connect"),
      ),
      shuffleOrder: complete ? queue.shuffleOrder : null,
      nextUpLength: complete ? queue.nextUpLength : 0,
      position: Duration(milliseconds: (position * 1000).round()),
      loop: FinampLoopMode.values.where((m) => m.name == queue.repeat).firstOrNull,
      beginPlaying: beginPlaying,
    );
  }

  // ---------------------------------------------------------------------------
  // RemotePlayback: what the player and queue forward
  // ---------------------------------------------------------------------------

  void _setLocal({bool? playing, Duration? position}) {
    if (position != null) {
      _position = position;
      _positionAt = DateTime.now();
    } else if (playing != null && playing != _playing) {
      _position = this.position;
      _positionAt = DateTime.now();
    }
    if (playing != null) _playing = playing;
    _player.refreshRemoteState();
  }

  @override
  Future<void> play() async {
    _setLocal(playing: true);
    await _connect.sendCommand("play");
  }

  @override
  Future<void> pause() async {
    _setLocal(playing: false);
    await _connect.sendCommand("pause");
  }

  @override
  Future<void> next() => _connect.sendCommand("next");

  @override
  Future<void> previous() => _connect.sendCommand("previous");

  @override
  Future<void> seek(Duration position) async {
    _setLocal(position: position);
    await _connect.sendCommand("seek", position: position.inMilliseconds / 1000);
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _connect.sendCommand("volume", volume: volume);
  }

  @override
  Future<void> skipByOffset(int offset) => _connect.sendCommand("skipBy", args: {"offset": offset});

  @override
  Future<void> queueCommand(String action, [Map<String, dynamic> args = const {}]) => _connect.sendCommand(
    action,
    args: args["items"] is List
        ? {...args, "items": withConnectSourceHints((args["items"] as List).cast<Map<String, dynamic>>())}
        : args,
  );

  @override
  Future<void> playItems(
    List<Map<String, dynamic>> items, {
    required int startIndex,
    List<int>? shuffleOrder,
    bool shuffle = false,
  }) async {
    await _connect.playQueue(
      ConnectQueue(
        items: withConnectSourceHints(items),
        index: startIndex,
        position: 0,
        shuffleOrder: shuffleOrder,
        repeat: _queue.loopMode.name,
      ),
    );
    if (shuffle && shuffleOrder == null) await queueCommand("shuffle", {"on": true});
  }
}
