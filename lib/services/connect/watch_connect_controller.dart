import 'dart:async';

import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/media_source_service.dart';
import 'package:diapason/services/connect/connect_library.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/connect/connect_source_mapping.dart';
import 'package:diapason/services/connect/watch_setup.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/models/media_source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Where the watch lists music from.
enum WatchLibrarySource {
  /// The controlled device's library, over Connect (protocol 2).
  device,

  /// The sources configured on the watch itself; what is picked is sent to the device as tracks.
  watch,
}

/// The watch side of Diapason Connect. A watch plays nothing: it picks a device on the network, shows what it plays,
/// drives it, and browses a library (the device's, or its own sources') to send music to it.
///
/// The device picked last is remembered (by name, since its address and token change whenever it restarts) and
/// reconnected to at launch, when the app comes back to the foreground, and whenever it reappears after dropping off
/// the network. While the app is in the background the watch stops polling, to spare the battery.
class WatchConnectController with WidgetsBindingObserver {
  static final _log = Logger("WatchConnectController");

  ConnectService get _connect => GetIt.instance<ConnectService>();

  ValueListenable<ConnectDevice?> get device => _connect.connectedDevice;
  ValueListenable<ConnectStatus?> get status => _connect.remoteStatus;

  /// The players on the network (other watches are left out).
  final ValueNotifier<List<ConnectDevice>> players = ValueNotifier(const []);

  /// Set while the remembered device is being looked for after it dropped off or the app came back.
  final ValueNotifier<bool> reconnecting = ValueNotifier(false);

  /// The controlled device's queue, refreshed whenever its version changes.
  final ValueNotifier<ConnectQueue?> queue = ValueNotifier(null);

  String get _wantedName => FinampSettingsHelper.finampSettings.watchConnectDeviceName;

  /// The name of the device the watch reconnects to; empty when it remembers none.
  String get rememberedName => _wantedName;

  Timer? _retryTimer;
  bool _inForeground = true;
  bool _fetchingQueue = false;
  String? _queueVersion;

  void attach() {
    WidgetsBinding.instance.addObserver(this);
    _connect.devices.addListener(_onDevices);
    _connect.remoteStatus.addListener(_onStatus);
    _connect.connectedDevice.addListener(_onDevice);
    _connect.onConnectionLost = (lost) {
      _log.info("Lost ${lost.name}; looking for it again");
      _startLooking();
    };
    unawaited(_connect.startDiscovery());
    if (_wantedName.isNotEmpty) _startLooking();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _inForeground) return;
    _inForeground = foreground;
    if (foreground) {
      unawaited(_connect.startDiscovery());
      if (_wantedName.isNotEmpty) _startLooking();
    } else {
      // Nothing to show while nobody looks: stop polling and browsing the network.
      _stopLooking();
      _connect.disconnect();
      unawaited(_connect.stopDiscovery());
    }
  }

  void _onDevices() {
    players.value = _connect.devices.value.where((d) => !d.isWatch).toList();
    if (_retryTimer != null) unawaited(_tryReconnect());
  }

  void _onDevice() {
    if (device.value == null) {
      queue.value = null;
      _queueVersion = null;
    }
  }

  void _onStatus() {
    final version = status.value?.queueVersion;
    if (version != null && version != _queueVersion) unawaited(refreshQueue());
  }

  void _startLooking() {
    if (device.value != null || !_inForeground) return;
    reconnecting.value = true;
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_tryReconnect()));
    unawaited(_tryReconnect());
  }

  void _stopLooking() {
    _retryTimer?.cancel();
    _retryTimer = null;
    reconnecting.value = false;
  }

  bool _trying = false;

  Future<void> _tryReconnect() async {
    if (_trying || device.value != null) return _stopLookingIfConnected();
    final candidate = players.value.where((d) => d.name == _wantedName).firstOrNull;
    if (candidate == null) {
      // mDNS answers can be missed: browse again now and then.
      await _connect.stopDiscovery();
      await _connect.startDiscovery();
      return;
    }
    _trying = true;
    try {
      if (await _connect.connect(candidate)) _log.info("Reconnected to ${candidate.name}");
    } finally {
      _trying = false;
    }
    _stopLookingIfConnected();
  }

  void _stopLookingIfConnected() {
    if (device.value != null) _stopLooking();
  }

  /// Starts controlling [target] and remembers it. False when it does not answer.
  Future<bool> select(ConnectDevice target) async {
    _stopLooking();
    if (device.value != null && device.value != target) _connect.disconnect();
    final ok = await _connect.connect(target);
    if (ok) FinampSetters.setWatchConnectDeviceName(target.name);
    return ok;
  }

  /// Stops controlling the device and forgets it.
  void forget() {
    _stopLooking();
    _connect.disconnect();
    FinampSetters.setWatchConnectDeviceName("");
  }

  /// Browses the network again, e.g. when the device list is opened.
  Future<void> rescan() async {
    await _connect.stopDiscovery();
    await _connect.startDiscovery();
  }

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  Future<bool> playPause() => _connect.sendCommand((status.value?.isPlaying ?? false) ? "pause" : "play");
  Future<bool> next() => _connect.sendCommand("next");
  Future<bool> previous() => _connect.sendCommand("previous");
  Future<bool> seek(double seconds) => _connect.sendCommand("seek", position: seconds);
  Future<bool> setVolume(double volume) => _connect.sendCommand("volume", volume: volume.clamp(0.0, 1.0));

  /// Jumps to the track at [linearIndex] of the device's [queue].
  Future<bool> jumpTo(int linearIndex) async {
    final offset = queue.value?.offsetTo(linearIndex, from: status.value?.queueIndex);
    if (offset == null) return false;
    if (offset == 0) return true;
    return _connect.sendCommand("skipBy", args: {"offset": offset});
  }

  Future<void> refreshQueue() async {
    if (_fetchingQueue) return;
    _fetchingQueue = true;
    try {
      final fetched = await _connect.fetchQueue();
      if (fetched != null) {
        _queueVersion = fetched.version;
        queue.value = fetched;
      }
    } finally {
      _fetchingQueue = false;
    }
  }

  /// Where the artwork of the controlled device's [song] can be loaded from.
  Uri? artFor(ConnectSong song, {int size = 300}) {
    if (status.value?.canBrowse ?? false) return _connect.artUrl(song.id, size: size);
    final art = song.art;
    return art == null || art.isEmpty ? null : Uri.tryParse(art);
  }

  // ---------------------------------------------------------------------------
  // Library
  // ---------------------------------------------------------------------------

  /// The watch has sources of its own to browse.
  bool get hasOwnSources =>
      GetIt.instance.isRegistered<BackendRegistry>() && GetIt.instance<BackendRegistry>().configured.isNotEmpty;

  /// The device can be browsed over Connect.
  bool get deviceBrowsable => status.value?.canBrowse ?? false;

  /// Where to browse by default: the device when it can be, else the watch's own sources when it has some.
  WatchLibrarySource? get defaultLibrarySource => deviceBrowsable
      ? WatchLibrarySource.device
      : hasOwnSources
      ? WatchLibrarySource.watch
      : null;

  /// A listing; null when it could not be loaded.
  Future<List<ConnectBrowseItem>?> browse(WatchLibrarySource source, ConnectBrowseRequest request) async {
    switch (source) {
      case WatchLibrarySource.device:
        return _connect.browse(request);
      case WatchLibrarySource.watch:
        try {
          return (await browseLibraryItems(request)).map(toBrowseItem).toList();
        } catch (e) {
          _log.warning("Could not browse the watch's sources: $e");
          return null;
        }
    }
  }

  Uri? artUrlOf(WatchLibrarySource source, ConnectBrowseItem item, {int size = 120}) {
    if (!item.hasArt) return null;
    return switch (source) {
      WatchLibrarySource.device => _connect.artUrl(item.id, size: size),
      WatchLibrarySource.watch => null,
    };
  }

  /// Headers and URL for an item of the watch's own library (the source's server, reached directly).
  Future<({Uri url, Map<String, String> headers})?> ownArtOf(ConnectBrowseItem item, {int size = 120}) async {
    final resolved = (await resolveLibraryIds([item.id])).firstOrNull;
    return resolved == null ? null : artworkOf(resolved, size: size);
  }

  /// Sends [item] to the device: played (from [startIndex] among its tracks when it is a container, or as the
  /// [startIndex]th of [siblings] when given), shuffled, played next or queued. False when it did not get there.
  Future<bool> send(
    WatchLibrarySource source,
    ConnectBrowseItem item,
    ConnectPlayMode mode, {
    List<ConnectBrowseItem>? siblings,
  }) async {
    final playable = siblings?.where((s) => s.isTrack).toList();
    final useSiblings =
        item.isTrack &&
        playable != null &&
        playable.length > 1 &&
        mode != ConnectPlayMode.next &&
        mode != ConnectPlayMode.queue;
    final ids = useSiblings ? playable.map((s) => s.id).toList() : [item.id];
    final startIndex = useSiblings ? playable.indexWhere((s) => s.id == item.id).clamp(0, ids.length - 1) : 0;

    switch (source) {
      case WatchLibrarySource.device:
        return _connect.sendCommand(
          "playItem",
          args: {if (ids.length == 1) "id": ids.single else "ids": ids, "mode": mode.name, "startIndex": startIndex},
        );
      case WatchLibrarySource.watch:
        // Older devices (and libraries the device may not have): send the tracks themselves, which the device maps
        // to its own sources (see connect_source_mapping).
        final items = await resolveLibraryIds(ids);
        final tracks = await tracksForRequest(items);
        if (tracks.isEmpty) return false;
        final json = withConnectSourceHints([for (final t in tracks) t.toJson()]);
        switch (mode) {
          case ConnectPlayMode.play || ConnectPlayMode.shuffle:
            final shuffle = mode == ConnectPlayMode.shuffle;
            final order = shuffle ? (List.generate(json.length, (i) => i)..shuffle()) : null;
            return _connect.playQueue(
              ConnectQueue(
                items: json,
                index: shuffle ? order!.first : startIndex.clamp(0, json.length - 1),
                position: 0,
                shuffleOrder: order,
                playing: true,
              ),
            );
          case ConnectPlayMode.next:
            return _connect.sendCommand("addNext", args: {"items": json});
          case ConnectPlayMode.queue:
            return _connect.sendCommand("addToQueue", args: {"items": json});
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Set-up
  // ---------------------------------------------------------------------------

  /// While set-up is on screen the watch shows up on phones (as a watch, never as a speaker) and takes the accounts
  /// they send. Returns the offer stream to listen to.
  ValueListenable<SourceOffer?> startReceivingAccounts() {
    _connect.acceptSources = true;
    unawaited(_connect.setAdvertised(true));
    return _connect.sourceOffer;
  }

  void stopReceivingAccounts() {
    _connect.acceptSources = false;
    _connect.sourceOffer.value = null;
    unawaited(_connect.setAdvertised(false));
  }

  void declineOffer() => _connect.sourceOffer.value = null;

  /// Adds the accounts of [offer] the watch does not have yet. Returns how many were added.
  Future<int> importOffer(SourceOffer offer) async {
    final sources = GetIt.instance<MediaSourceService>();
    final added = newSourcesFromOffer(
      offer,
      existing: sources.sources,
      newId: (kind, taken) => MediaSourceConfig.newSourceId(kind, taken),
    );
    for (final config in added) {
      await sources.addSource(config);
    }
    _connect.sourceOffer.value = null;
    _log.info("Added ${added.length} account(s) sent by ${offer.from}");
    return added.length;
  }
}
