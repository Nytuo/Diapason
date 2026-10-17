import 'dart:async';
import 'dart:core';
import 'dart:io';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/jellyfin_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/jellyfin_api_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

Logger _rpcLogger = Logger("DiscordRPC");
bool lastState = false;
Timer? _timer;
final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
final _finampUserHelper = GetIt.instance<FinampUserHelper>();
final _aggregateBackend = GetIt.instance<AggregateBackend>();
BaseItemDto? artistItem;

enum _RpcStatus { running, transition, stopped }

_RpcStatus _status = _RpcStatus.stopped;
_RpcStatus _targetStatus = _RpcStatus.stopped;

class DiscordRpc {
  static const applicationId = "1507760797823275098";

  static bool _initialized = false;
  static String? _lastNote;

  static Future<void> initialize() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      _rpcLogger.warning("Discord RPC is only supported on Desktop platforms, skipping initialization.");
      return;
    }

    try {
      await FlutterDiscordRPC.initialize(applicationId);
    } catch (e, stack) {
      if (!e.toString().contains("already been initialized")) {
        _rpcLogger.severe("Couldn't initialise the Discord RPC bridge; Rich Presence is unavailable", e, stack);
        return;
      }
    }
    _initialized = true;
    FinampSettingsHelper.finampSettingsListener.addListener(_reEvaluate);
    _reEvaluate();
    _rpcLogger.info("Initialized (application $applicationId)");
  }

  static void _reEvaluate() {
    final enabled = FinampSettingsHelper.finampSettings.rpcEnabled;
    final offline = FinampSettingsHelper.finampSettings.isOffline;
    final note = !enabled ? "off" : (offline ? "offline" : "on");
    if (note != _lastNote) {
      _lastNote = note;
      if (note == "off") {
        _rpcLogger.info("Rich Presence is switched off (Settings → Playback → Discord Rich Presence)");
      } else if (note == "offline") {
        _rpcLogger.info("Rich Presence is paused while offline mode is on");
      }
    }
    (enabled && !offline) ? start() : stop();
  }

  static Future<void> start() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS) || !_initialized) {
      return;
    }
    _targetStatus = _RpcStatus.running;
    if (_status == _RpcStatus.stopped) {
      _status = _RpcStatus.transition;
      _rpcLogger.info("Starting RPC");

      _connectionSubscription?.cancel();
      _connectionSubscription = FlutterDiscordRPC.instance.isConnectedStream.listen((connected) {
        if (connected) {
          _onConnected();
        } else {
          _timer?.cancel();
          _timer = null;
        }
      });

      try {
        await FlutterDiscordRPC.instance.connect(autoRetry: true, retryDelay: Duration(seconds: 3));
      } catch (e, stack) {
        _rpcLogger.severe("Failed to start; is the Discord desktop app running?", e, stack);
        await stop(force: true);
        return;
      }
      if (!FlutterDiscordRPC.instance.isConnected) {
        _rpcLogger.info("Discord isn't reachable yet; retrying every 3 seconds until it is");
      }

      _status = _RpcStatus.running;

      if (_targetStatus == _RpcStatus.stopped) await stop();
    }
  }

  static StreamSubscription<bool>? _connectionSubscription;

  static void _onConnected() {
    if (_timer != null) return;
    _rpcLogger.info("Connected to Discord");
    updateRPC();
    _timer = Timer.periodic(Duration(seconds: 15), (timer) => updateRPC());
  }

  static Future<void> stop({bool force = false}) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    _targetStatus = _RpcStatus.stopped;
    if (_status == _RpcStatus.running || force) {
      _rpcLogger.info("Stopping RPC");

      _status = _RpcStatus.transition;
      _timer?.cancel();
      _timer = null;
      artistItem = null;
      lastState = false;
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;

      try {
        if (FlutterDiscordRPC.instance.isConnected) {
          await FlutterDiscordRPC.instance.clearActivity();
        }
        await FlutterDiscordRPC.instance.disconnect();
      } catch (e) {
        _rpcLogger.severe("Failed to Stop", e);
      }

      _status = _RpcStatus.stopped;

      if (_targetStatus == _RpcStatus.running) await start();
    }
  }

  static Future<void> updateRPC() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    if (!FlutterDiscordRPC.instance.isConnected) return;
    RPCActivity? currentState;
    try {
      currentState = await _render();
    } catch (e) {
      _rpcLogger.warning("Something went wrong during RPC rendering", e);
      return;
    }

    if (currentState == null) {
      if (lastState) {
        _rpcLogger.finer("Not playing anymore, clearing activity");
        await FlutterDiscordRPC.instance.clearActivity();
        lastState = false;
      }
      return;
    }

    try {
      await FlutterDiscordRPC.instance.setActivity(activity: currentState);
      lastState = true;
      _rpcLogger.finest("Updated");
    } catch (e, stack) {
      _rpcLogger.warning("Discord refused the presence update", e, stack);
    }
  }

  static bool isAddressInLocalAddressRange(String address) {
    final regex = RegExp(r"(^127\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.)");
    final host = Uri.parse(address).host;
    final isPrivateIp = regex.hasMatch(host);
    final isPrivateDomain = host.split('.').length == 1;
    return isPrivateIp || isPrivateDomain;
  }

  static const _credentialParams = {"u", "t", "s", "p", "api_key", "apikey", "token", "x-plex-token", "x-emby-token"};

  @visibleForTesting
  static String? shareableImage(Uri? url) {
    if (url == null || !url.isScheme("https") && !url.isScheme("http")) return null;
    if (isAddressInLocalAddressRange(url.toString())) return null;
    if (url.queryParameters.keys.any((k) => _credentialParams.contains(k.toLowerCase()))) return null;
    return url.toString();
  }

  static (String?, String) _fetchImageUrls(BaseItemDto baseItem) {
    final backend = GetIt.instance<BackendRegistry>().forItem(baseItem);
    if (backend is! JellyfinBackend) {
      final smallImage = artistItem == null
          ? null
          : shareableImage(_aggregateBackend.imageUrl(artistItem!, maxHeight: 128, maxWidth: 128));
      final largeImage =
          shareableImage(_aggregateBackend.imageUrl(baseItem, maxHeight: 128, maxWidth: 128)) ??
          FinampSettingsHelper.finampSettings.rpcIcon.toString();
      return (smallImage, largeImage);
    }

    String? smallImage;
    String? largeImage;

    final activeAddress = _finampUserHelper.currentUser?.baseURL;
    final activeAddressIsPrivate = activeAddress != null && isAddressInLocalAddressRange(activeAddress);

    bool forcePublicAddress = false;
    bool skipUrlGetting = false;

    if (activeAddressIsPrivate) {
      final publicAddress = _finampUserHelper.currentUser!.publicAddress;
      final publicAddressIsPrivate = isAddressInLocalAddressRange(publicAddress);
      forcePublicAddress = true;
      skipUrlGetting = publicAddressIsPrivate;
    }

    if (!skipUrlGetting) {
      smallImage = artistItem == null
          ? null
          : _jellyfinApiHelper
                .getImageUrl(item: artistItem!, maxHeight: 128, maxWidth: 128, forcePublicAddress: forcePublicAddress)
                ?.toString();
      largeImage = _jellyfinApiHelper
          .getImageUrl(item: baseItem, maxHeight: 128, maxWidth: 128, forcePublicAddress: forcePublicAddress)
          ?.toString();
    }

    largeImage ??= FinampSettingsHelper.finampSettings.rpcIcon.toString();

    return (smallImage, largeImage);
  }

  static Future<RPCActivity?> _render() async {
    final audioService = GetIt.instance<MusicPlayerBackgroundTask>();
    final playbackState = audioService.playbackState.valueOrNull;
    final mediaItem = audioService.mediaItem.valueOrNull;

    if (playbackState?.playing == null || !playbackState!.playing) {
      return null;
    }

    final baseItem = BaseItemDto.fromJson(mediaItem!.extras!["itemJson"] as Map<String, dynamic>);

    if (baseItem.artistItems?.isNotEmpty ?? false) {
      if (artistItem == null || !baseItem.artistItems!.any((v) => v.id == artistItem?.id)) {
        artistItem = await _aggregateBackend.getItemById(baseItem.artistItems!.first.id);
      }
    } else {
      artistItem = null;
    }

    final now = (DateTime.now().millisecondsSinceEpoch / 1000).truncate();
    final progress = playbackState.position.inSeconds;
    final duration = mediaItem.duration!.inSeconds;

    final images = _fetchImageUrls(baseItem);
    final start = now - progress;
    final end = now + (duration - progress);
    final title = mediaItem.title;
    final artist = mediaItem.artist;
    final album = mediaItem.album;

    return RPCActivity(
      activityType: ActivityType.listening,
      details: title,
      state: artist,
      assets: RPCAssets(
        smallImage: images.$1,
        smallText: images.$1 == null ? null : artist,
        largeImage: images.$2,
        largeText: album,
      ),
      timestamps: RPCTimestamps(start: start, end: end),
    );
  }
}
