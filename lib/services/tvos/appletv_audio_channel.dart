import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_tvos/flutter_tvos.dart';
import 'package:logging/logging.dart';

/// Dart-side bridge to `tvos/Runner/Playback/AppleTvAudioChannel.swift`.
///
/// On every other platform Diapason plays audio through just_audio +
/// audio_service; neither has a tvOS build, so tvOS plays audio natively via
/// AVPlayer and reports Now Playing / Siri Remote state through
/// MPNowPlayingInfoCenter instead. This class is the foundation for that
/// path — it is not yet wired into the app's queue/session logic
/// (music_player_background_task.dart), which still assumes just_audio.
/// A follow-up needs to branch playback backend selection on
/// [TvOSInfo.isTvOS] and drive this channel the way the rest of the app
/// drives just_audio's [AudioPlayer].
class AppleTvAudioChannel {
  AppleTvAudioChannel._();

  static final _log = Logger('AppleTvAudioChannel');
  static const _channel = MethodChannel('fr.nytuo.diapason/appletv_audio');

  static AppleTvAudioChannel? _instance;

  /// True only on a real tvOS runtime; false everywhere else, including iOS.
  ///
  /// flutter_tvos only links its native symbols into tvOS builds (see its
  /// `ffiPlugin` platform declaration), so [TvOSInfo.isTvOS] throws
  /// `Invalid argument(s): Failed to lookup symbol` on iOS/macOS/Android
  /// instead of just returning false there. Guard the lookup and treat any
  /// failure as "not tvOS".
  static bool get isSupported => _isSupported ??= _probeIsTvOS();

  static bool? _isSupported;

  static bool _probeIsTvOS() {
    try {
      return TvOSInfo.isTvOS;
    } catch (e, st) {
      _log.warning('TvOSInfo.isTvOS lookup failed; assuming non-tvOS platform', e, st);
      return false;
    }
  }

  static AppleTvAudioChannel get instance {
    assert(isSupported, 'AppleTvAudioChannel is only available on tvOS');
    return _instance ??= AppleTvAudioChannel._();
  }

  final _readyController = StreamController<Duration>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _completeController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _remoteCommandController = StreamController<AppleTvRemoteCommand>.broadcast();

  /// Fires once per [load] when the item becomes playable, with its duration.
  Stream<Duration> get onReady => _readyController.stream;

  /// Fires roughly every 500ms during playback.
  Stream<Duration> get onPositionChanged => _positionController.stream;

  /// Fires when the current item finishes playing.
  Stream<void> get onComplete => _completeController.stream;

  /// Fires on player/network error, with a human-readable message.
  Stream<String> get onError => _errorController.stream;

  /// Fires when the Siri Remote / Now Playing UI issues a transport command.
  Stream<AppleTvRemoteCommand> get onRemoteCommand => _remoteCommandController.stream;

  bool _handlerAttached = false;

  void _ensureHandlerAttached() {
    if (_handlerAttached) return;
    _handlerAttached = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onReady':
        final args = call.arguments as Map<dynamic, dynamic>;
        _readyController.add(Duration(milliseconds: args['durationMs'] as int));
      case 'onPositionChanged':
        final args = call.arguments as Map<dynamic, dynamic>;
        _positionController.add(Duration(milliseconds: args['positionMs'] as int));
      case 'onComplete':
        _completeController.add(null);
      case 'onError':
        final args = call.arguments as Map<dynamic, dynamic>;
        final message = args['message'] as String? ?? 'unknown tvOS player error';
        _log.warning('native playback error: $message');
        _errorController.add(message);
      case 'onRemoteCommand':
        final args = call.arguments as Map<dynamic, dynamic>;
        final command = AppleTvRemoteCommand.fromWire(args);
        if (command != null) _remoteCommandController.add(command);
      default:
        _log.fine('unhandled native call: ${call.method}');
    }
  }

  Future<void> load(String url) async {
    _ensureHandlerAttached();
    await _channel.invokeMethod('load', {'url': url});
  }

  Future<void> play() => _channel.invokeMethod('play');

  Future<void> pause() => _channel.invokeMethod('pause');

  Future<void> stop() => _channel.invokeMethod('stop');

  Future<void> seek(Duration position) =>
      _channel.invokeMethod('seek', {'positionMs': position.inMilliseconds});

  Future<void> setVolume(double volume) => _channel.invokeMethod('setVolume', {'volume': volume});

  Future<void> setNowPlayingInfo({
    required String title,
    String? artist,
    String? album,
    String? artworkUrl,
    Duration? duration,
    Duration? position,
  }) {
    return _channel.invokeMethod('setNowPlayingInfo', {
      'title': title,
      'artist': ?artist,
      'album': ?album,
      'artworkUrl': ?artworkUrl,
      'durationMs': ?duration?.inMilliseconds,
      'positionMs': ?position?.inMilliseconds,
    });
  }
}

/// Bridge to `tvos/Runner/Playback/AppleTvSystemChannel.swift`.
///
/// Stands in for package_info_plus, which has no tvOS plugin implementation
/// (see the Swift side for why its tvOS fork isn't used instead).
class AppleTvSystemChannel {
  AppleTvSystemChannel._();

  static const _channel = MethodChannel('fr.nytuo.diapason/appletv_system');

  /// Raw fields matching PackageInfo's constructor: appName, packageName,
  /// version, buildNumber.
  static Future<Map<String, String>> getPackageInfo() async {
    final result = await _channel.invokeMapMethod<String, String>('getPackageInfo');
    return result ?? const {};
  }
}

enum AppleTvRemoteCommand {
  play,
  pause,
  next,
  previous,
  seek;

  static AppleTvRemoteCommand? fromWire(Map<dynamic, dynamic> args) {
    switch (args['command'] as String?) {
      case 'play':
        return AppleTvRemoteCommand.play;
      case 'pause':
        return AppleTvRemoteCommand.pause;
      case 'next':
        return AppleTvRemoteCommand.next;
      case 'previous':
        return AppleTvRemoteCommand.previous;
      case 'seek':
        return AppleTvRemoteCommand.seek;
      default:
        return null;
    }
  }
}
