import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/stream_cache_service.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/models/jellyfin_models.dart' as jellyfin_models;
import 'package:diapason/services/current_track_metadata_provider.dart';
import 'package:diapason/services/favorite_provider.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/playback_history_service.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/radio_service_helper.dart' as RadioServiceHelper;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'android_auto_helper.dart';
import 'finamp_settings_helper.dart';
import 'ios_helpers.dart';
import 'metadata_provider.dart';

enum FadeDirection { fadeIn, fadeOut, none }

class FadeState {
  // current fade volume
  late final double fadeVolume;

  // volume step sizes for fade-in and fade-out
  final double volumeFadeOutStepSize;
  final double volumeFadeInStepSize;

  // current fade direction
  final FadeDirection fadeDirection;

  FadeState({
    required this.fadeVolume,
    this.volumeFadeInStepSize = 0.0,
    this.volumeFadeOutStepSize = 0.0,
    this.fadeDirection = FadeDirection.none,
  });

  FadeState copyWith({
    double? recoverVolume,
    double? fadeVolume,
    double? volumeFadeInStepSize,
    double? volumeFadeOutStepSize,
    FadeDirection? fadeDirection,
  }) {
    return FadeState(
      fadeVolume: fadeVolume ?? this.fadeVolume,
      volumeFadeInStepSize: volumeFadeInStepSize ?? this.volumeFadeInStepSize,
      volumeFadeOutStepSize: volumeFadeOutStepSize ?? this.volumeFadeOutStepSize,
      fadeDirection: fadeDirection ?? this.fadeDirection,
    );
  }
}

class PlayerVolumeController {
  static final _volumeLogger = Logger("Volume");

  PlayerVolumeController(this._player) {
    _updateVolume();
  }

  final AudioPlayer _player;

  double _internalVolume = FinampSettingsHelper.finampSettings.currentVolume;
  double _replayGainVolume = 1.0;
  double _fadeVolume = 1.0;
  bool isDucked = false;

  Future<void> setInternalVolume(double volume) {
    if (volume == _internalVolume) return Future.value();
    _internalVolume = volume;
    FinampSetters.setCurrentVolume(volume);
    return _updateVolume();
  }

  Future<void> setReplayGainVolume(double volume) {
    if (volume == _replayGainVolume) return Future.value();
    _replayGainVolume = volume;
    return _updateVolume();
  }

  Future<void> setFadeVolume(double volume) {
    if (volume == _fadeVolume) return Future.value();
    _fadeVolume = volume;
    return _updateVolume();
  }

  void duck() {
    if (isDucked) return;
    isDucked = true;
    _updateVolume();
  }

  void unduck() {
    if (!isDucked) return;
    isDucked = false;
    _updateVolume();
  }

  Future<void> _updateVolume() {
    var vol1 = _internalVolume.clamp(0.0, 1.0);
    var vol2 = _replayGainVolume.clamp(0.0, 1.0);
    var vol3 = _fadeVolume.clamp(0.0, 1.0);
    var duckingFactor = isDucked ? 0.3 : 1.0;
    var totalVol = vol1 * vol2 * vol3 * duckingFactor;
    _volumeLogger.info(
      "Setting volume to $totalVol - user: $_internalVolume gain: $_replayGainVolume fade: $_fadeVolume, ducking: $isDucked",
    );
    return _player.setVolume(totalVol.clamp(0.0, 1.0));
  }
}

/// This provider handles the currently playing music so that multiple widgets
/// can control music.
class MusicPlayerBackgroundTask extends BaseAudioHandler with SeekHandler, QueueHandler {
  final _androidAutoHelper = GetIt.instance<AndroidAutoHelper>();

  AppLocalizations? _appLocalizations;

  late final AudioPlayer _playerA;
  late final AudioPlayer _playerB;
  final _activePlayerIndexSubject = BehaviorSubject<int>.seeded(0);
  int get _activePlayerIndex => _activePlayerIndexSubject.value;
  AudioPlayer get _player => _activePlayerIndex == 0 ? _playerA : _playerB;
  AudioPlayer get _standbyPlayer => _activePlayerIndex == 0 ? _playerB : _playerA;

  Stream<PlaybackEvent> get _activePlaybackEventStream =>
      _activePlayerIndexSubject.switchMap((i) => (i == 0 ? _playerA : _playerB).playbackEventStream);
  Stream<PlayerException> get _activeErrorStream =>
      _activePlayerIndexSubject.switchMap((i) => (i == 0 ? _playerA : _playerB).errorStream);
  Stream<Duration> get _activePositionStream =>
      _activePlayerIndexSubject.switchMap((i) => (i == 0 ? _playerA : _playerB).positionStream);
  Stream<ProcessingState> get _activeProcessingStateStream =>
      _activePlayerIndexSubject.switchMap((i) => (i == 0 ? _playerA : _playerB).processingStateStream);
  Stream<int?> get _activeCurrentIndexStream =>
      _activePlayerIndexSubject.switchMap((i) => (i == 0 ? _playerA : _playerB).currentIndexStream);
  Stream<Duration?> get _activeDurationStream =>
      _activePlayerIndexSubject.switchMap((i) => (i == 0 ? _playerA : _playerB).durationStream);

  Stream<int?> get androidAudioSessionIdStream =>
      _activePlayerIndexSubject.switchMap((i) => (i == 0 ? _playerA : _playerB).androidAudioSessionIdStream);

  late final AudioPipeline _audioPipeline;
  late final List<AndroidAudioEffect> _androidAudioEffects;
  late final List<DarwinAudioEffect> _iosAudioEffects;

  AndroidLoudnessEnhancer? _loudnessEnhancerEffect;

  final _audioServiceBackgroundTaskLogger = Logger("MusicPlayerBackgroundTask");
  final _volumeNormalizationLogger = Logger("VolumeNormalization");
  final _outputLogger = Logger("Output");

  static const Duration _skipPlayPauseGuardWindow = Duration(milliseconds: 50);

  /// Timestamp of the most recent explicit skip command (next/previous).
  DateTime? _lastSkipCommandAt;

  DateTime? _lastManualSeekAt;
  static const Duration _crossfadeSeekGuardWindow = Duration(seconds: 1);

  void _markManualSeek() => _lastManualSeekAt = DateTime.now();

  // Init the new sleep timer with a length of 0
  // SleepTimer sleepTimer = SleepTimer(SleepTimerType.duration, 0);

  /// Holds the current sleep timer, if any. This is a ValueNotifier so that
  /// widgets like SleepTimerButton can update when the sleep timer is/isn't
  /// null.
  final ValueNotifier<SleepTimer?> _timer = ValueNotifier<SleepTimer?>(null);
  ValueListenable<SleepTimer?> get timer => _timer;

  Future<bool> Function()? _queueCallbackPreviousTrack;

  List<int> get shuffleIndices => _player.shuffleIndices;
  List<AudioSource> get audioSources => _player.audioSources;

  double iosBaseVolumeGainFactor = 1.0;
  late final PlayerVolumeController _volumeA;
  late final PlayerVolumeController _volumeB;
  PlayerVolumeController get _volume => _activePlayerIndex == 0 ? _volumeA : _volumeB;
  PlayerVolumeController get _standbyVolume => _activePlayerIndex == 0 ? _volumeB : _volumeA;
  Duration minBufferDuration = Duration(seconds: 90);

  final _audioFadeStepDuration = Duration(milliseconds: 50);
  late final BehaviorSubject<FadeState> fadeState;

  final outputSwitcherChannel = MethodChannel('fr.nytuo.diapason/output_switcher');

  bool get _shouldIgnorePlayPauseAfterRecentSkip {
    final lastSkipCommandAt = _lastSkipCommandAt;
    if (lastSkipCommandAt == null) return false;

    final elapsed = DateTime.now().difference(lastSkipCommandAt);
    if (elapsed <= _skipPlayPauseGuardWindow) {
      _audioServiceBackgroundTaskLogger.fine(
        "Ignoring play/pause because skip was ${elapsed.inMilliseconds}ms ago (threshold ${_skipPlayPauseGuardWindow.inMilliseconds}ms)",
      );
      return true;
    }
    return false;
  }

  Future<void> showOutputSwitcherDialog() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      _outputLogger.fine("Showing output switcher dialog");
      await outputSwitcherChannel.invokeMethod('showOutputSwitcherDialog');
      _outputLogger.finer("Output switcher dialog shown");
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to show output switcher dialog: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to show output switcher dialog: $e");
    }
  }

  Future<void> openBluetoothSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      _outputLogger.fine("Opening Bluetooth settings");
      await outputSwitcherChannel.invokeMethod('openBluetoothSettings');
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to open Bluetooth settings: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to open Bluetooth settings: $e");
    }
  }

  Future<List<FinampOutputRoute>> getRoutes() async {
    if (!Platform.isAndroid) {
      return [];
    }
    try {
      final List<Object?>? rawObjects = await outputSwitcherChannel.invokeMethod<List<Object?>>('getRoutes');

      final routes =
          rawObjects
              ?.map((obj) => Map<String, dynamic>.from(obj as Map))
              .map((route) => FinampOutputRoute.fromJson(route))
              .toList() ??
          [];
      return routes;
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to get routes: ${e.message}");
      return [];
    } catch (e) {
      _outputLogger.severe("Failed to get routes: $e");
      return [];
    }
  }

  Future<void> setOutputToDeviceSpeaker() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await outputSwitcherChannel.invokeMethod('setOutputToDeviceSpeaker');
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to switch output: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to switch output: $e");
    }
  }

  Future<void> setOutputToBluetoothDevice() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await outputSwitcherChannel.invokeMethod('setOutputToBluetoothDevice');
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to switch output: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to switch output: $e");
    }
  }

  Future<void> setOutputToRoute(FinampOutputRoute route) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await outputSwitcherChannel.invokeMethod('setOutputToRouteByName', {'name': route.name});
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to switch output: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to switch output: $e");
    }
  }

  static Future<void> configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(
      FinampSettingsHelper.finampSettings.duckOnAudioInterruption
          ? const AudioSessionConfiguration.music()
          : const AudioSessionConfiguration.music().copyWith(
              // disable Android automatic ducking (https://developer.android.com/media/optimize/audio-focus#automatic_ducking)
              // so that we can handle it manually, by setting the content type to "speech"
              // if we instead set `willPauseOnDucked` to `true`, Android will send us pause events instead of duck events
              // and then we don't know how to properly handle them (is this just a notification or a phone call?)
              androidAudioAttributes: const AndroidAudioAttributes(
                contentType: AndroidAudioContentType.speech,
                usage: AndroidAudioUsage.media,
              ),
            ),
    );
  }

  MusicPlayerBackgroundTask() {
    _audioServiceBackgroundTaskLogger.info("Starting audio service");

    if (Platform.isWindows || Platform.isLinux) {
      _audioServiceBackgroundTaskLogger.info("Initializing media-kit for Windows/Linux");
      JustAudioMediaKit.title = "Diapason";
      JustAudioMediaKit.prefetchPlaylist = true; // cache upcoming tracks, enable gapless playback
      JustAudioMediaKit.bufferSize = FinampSettingsHelper.finampSettings.bufferSizeMegabytes * 1024 * 1024;
      JustAudioMediaKit.ensureInitialized(linux: true, windows: true, macOS: false, iOS: false, android: false);
    }

    _androidAudioEffects = [];
    _iosAudioEffects = [];

    if (Platform.isAndroid && FinampSettingsHelper.finampSettings.useAndroidGainEffect) {
      _loudnessEnhancerEffect = AndroidLoudnessEnhancer();
      _androidAudioEffects.add(_loudnessEnhancerEffect!);
    } else {
      _loudnessEnhancerEffect = null;
    }

    _audioPipeline = AudioPipeline(androidAudioEffects: _androidAudioEffects, darwinAudioEffects: _iosAudioEffects);

    Duration maxBufferDuration = Duration(
      seconds: max(minBufferDuration.inSeconds, FinampSettingsHelper.finampSettings.bufferDuration.inSeconds),
    );

    AudioSession.instance.then((session) {
      bool wasPlayingBeforeInterruption = false;
      session.interruptionEventStream.listen((event) {
        bool customInterruptionHandlingNeeded = !FinampSettingsHelper.finampSettings.duckOnAudioInterruption;
        if (!customInterruptionHandlingNeeded) {
          return;
        }
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // if we are in here, then ducking should be disabled anyway, so this is a no-op
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              // Another app started playing audio and we should pause.
              wasPlayingBeforeInterruption = _player.playing;
              pause();
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // The interruption ended and we should unduck.
              // keeping this in here won't hurt, and ensures we never become stuck in a ducked state
              _volume.unduck();
              break;
            case AudioInterruptionType.pause:
              // The interruption ended and we should resume.
              if (wasPlayingBeforeInterruption) {
                play();
              }
              break;
            case AudioInterruptionType.unknown:
              // The interruption ended but we should not resume.
              break;
          }
        }
      });
      session.becomingNoisyEventStream.listen((_) {
        // The user unplugged/disconnected the headphones/speaker/car, so we should pause ~~or lower~~ the volume.
        if (FinampSettingsHelper.finampSettings.duckOnAudioInterruption) {
          // if this is enabled, we let the [AudioPlayer] handle this automatically, via [handleInterruptions]
        } else {
          // if ducking is disabled, the audio player doesn't handle interruptions on its own, so we need to make sure to pause
          pause();
        }
      });
      session.devicesChangedEventStream.listen((event) {
        _outputLogger.info('Devices added:   ${event.devicesAdded}');
        _outputLogger.info('Devices removed: ${event.devicesRemoved}');
      });
    });

    _playerA = _buildPlayer(audioPipeline: _audioPipeline, maxBufferDuration: maxBufferDuration);
    _playerB = _buildPlayer(audioPipeline: AudioPipeline(), maxBufferDuration: maxBufferDuration);
    _volumeA = PlayerVolumeController(_playerA);
    _volumeB = PlayerVolumeController(_playerB);

    try {
      _loudnessEnhancerEffect?.setEnabled(FinampSettingsHelper.finampSettings.volumeNormalizationActive);
      _loudnessEnhancerEffect?.setTargetGain(0.0);
    } catch (_) {
      // Assume we've hit https://github.com/UnicornsOnLSD/finamp/issues/1343 and disable loudness enhancer effect permanently
      FinampSetters.setUseAndroidGainEffect(false);
      _loudnessEnhancerEffect = null;
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.androidGainDisabled);
    }

    // calculate base volume gain for iOS as a linear factor, because just_audio doesn't yet support AudioEffect on iOS
    iosBaseVolumeGainFactor =
        pow(10.0, FinampSettingsHelper.finampSettings.volumeNormalizationIOSBaseGain / 20.0)
            as double; // https://sound.stackexchange.com/questions/38722/convert-db-value-to-linear-scale
    if (_loudnessEnhancerEffect == null) {
      _volumeNormalizationLogger.info("non-Android base volume gain factor: $iosBaseVolumeGainFactor");
    }

    // Propagate all events from the audio player to AudioService clients.
    int? replayQueueIndex;
    _activePlaybackEventStream.listen((event) async {
      final playerSequence = _player.sequenceState.sequence;
      if (playerSequence.isNotEmpty) {
        if (event.currentIndex != replayQueueIndex) {
          replayQueueIndex = event.currentIndex;
          if (replayQueueIndex != null && playerSequence.elementAtOrNull(replayQueueIndex!) != null) {
            var queueItem =
                // event.currentIndex is based on the original sequence, not the effectiveSequence
                playerSequence[replayQueueIndex!].tag as FinampQueueItem?;
            if (queueItem != null) {
              _applyVolumeNormalization(queueItem.item);
            }
          }
        }
      }
      playbackState.add(_transformEvent(event));
    });

    double prevIosGain = FinampSettingsHelper.finampSettings.volumeNormalizationIOSBaseGain;
    bool? prevNormActive = FinampSettingsHelper.finampSettings.volumeNormalizationActive;
    VolumeNormalizationMode prevNormMode = FinampSettingsHelper.finampSettings.volumeNormalizationMode;
    FinampSettingsHelper.finampSettingsListener.addListener(() {
      var iosGain = FinampSettingsHelper.finampSettings.volumeNormalizationIOSBaseGain;
      var normalizationActive = FinampSettingsHelper.finampSettings.volumeNormalizationActive;
      var normalizationMode = FinampSettingsHelper.finampSettings.volumeNormalizationMode;
      if (iosGain == prevIosGain && normalizationActive == prevNormActive && normalizationMode == prevNormMode) {
        return;
      }
      prevIosGain = iosGain;
      prevNormActive = normalizationActive;
      prevNormMode = normalizationMode;
      // update replay gain settings every time settings are changed
      iosBaseVolumeGainFactor =
          pow(10.0, iosGain / 20.0)
              as double; // https://sound.stackexchange.com/questions/38722/convert-db-value-to-linear-scale
      if (normalizationActive) {
        _loudnessEnhancerEffect?.setEnabled(true);
        _applyVolumeNormalization(mediaItem.valueOrNull);
      } else {
        _loudnessEnhancerEffect?.setEnabled(false);
        _volume.setReplayGainVolume(1.0); // disable replay gain on iOS
        _volumeNormalizationLogger.info("Replay gain disabled");
      }
    });

    // This is called each time queue (or at least previous and next items in it) changes
    // This unintended behavior is actually used to recalculate the `Dynamic`
    // normalization gain mode.
    // if user adds a track from the same album next to queue or makes previous
    // and next track in the queue not from the same album anymore (e.g. by
    // removing them from queue), volume gain is recalculated instantly so that
    // it is not changed on track change (where gapless playback will regress to
    // audible volume change).
    // This is possible because this callback is called on each queue change
    mediaItem.listen((currentTrack) {
      _applyVolumeNormalization(currentTrack);
    });

    // But sleepTimer doesn't want to listen on queue changes
    mediaItem.distinct().listen((currentTrack) {
      sleepTimer?.onTrackCompleted();
    });

    _activeErrorStream.listen((error) {
      _audioServiceBackgroundTaskLogger.severe("Player error: $error", error);
    });

    // trigger sleep timer early if we're almost at the end of the final track
    _activePositionStream.listen((position) {
      if (sleepTimer?.remainingTracks == 1 &&
          ((mediaItem.value?.duration ?? Duration.zero) - position).inMilliseconds / _player.speed <=
              // even if fade out is disabled, we stop a bit early to avoid advancing to the next track
              max(
                Duration(milliseconds: 500).inMilliseconds,
                FinampSettingsHelper.finampSettings.audioFadeOutDuration.inMilliseconds,
              )) {
        sleepTimer?.onTrackCompleted();
      }
    });

    // Special processing for state transitions.
    _activeProcessingStateStream.listen((event) async {
      if (event == ProcessingState.completed) {
        await handleEndOfQueue();
      }
    });

    fadeState = BehaviorSubject.seeded(FadeState(fadeVolume: 1.0));

    _setupCrossfade();
    _setupStreamCacheProgressTracking();
    _setupDurationReconciliation();
    _setupFlacSeekWarning();
  }

  void _setupFlacSeekWarning() {
    if (!Platform.isIOS) return;

    var warned = false;
    mediaItem.listen((item) {
      if (warned || item == null) return;
      final json = item.extras?["itemJson"] as Map<String, dynamic>?;
      if (json == null) return;
      if (item.extras?["shouldTranscode"] as bool? ?? false) return;

      final container = jellyfin_models.BaseItemDto.fromJson(json).container;
      if (container?.toLowerCase() != "flac") return;

      warned = true;
      _audioServiceBackgroundTaskLogger.warning(
        "Playing a FLAC on iOS ('${item.title}'): AVFoundation mis-seeks this container, "
        "so seeking will be inaccurate and playback can run past the end of the track.",
      );
      GlobalSnackbar.message((scaffold) => AppLocalizations.of(scaffold)!.flacSeekWarningIos);
    });
  }

  AudioPlayer _buildPlayer({required AudioPipeline audioPipeline, required Duration maxBufferDuration}) {
    return AudioPlayer(
      maxSkipsOnError: 0,
      handleInterruptions: FinampSettingsHelper.finampSettings.duckOnAudioInterruption,
      androidAudioOffloadPreferences: AndroidAudioOffloadPreferences(
        audioOffloadMode: FinampSettingsHelper.finampSettings.forceAudioOffloadingOnAndroid
            ? AndroidAudioOffloadMode.enabled
            : AndroidAudioOffloadMode.disabled,
        isGaplessSupportRequired: true,
        isSpeedChangeSupportRequired: true,
      ),
      audioLoadConfiguration: AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          targetBufferBytes: FinampSettingsHelper.finampSettings.bufferDisableSizeConstraints
              ? null
              : 1024 * 1024 * FinampSettingsHelper.finampSettings.bufferSizeMegabytes,
          minBufferDuration: FinampSettingsHelper.finampSettings.bufferDisableSizeConstraints
              ? maxBufferDuration
              : minBufferDuration,
          maxBufferDuration: FinampSettingsHelper.finampSettings.bufferDisableSizeConstraints
              ? (maxBufferDuration + Duration(seconds: 90))
              : maxBufferDuration,
          prioritizeTimeOverSizeThresholds: FinampSettingsHelper
              .finampSettings
              .bufferDisableSizeConstraints, // targetBufferBytes sets the absolute maximum, but if this false and maxBufferDuration is reached, buffering will end
          bufferForPlaybackDuration: Duration(seconds: 5),
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 10),
        ),
        darwinLoadControl: DarwinLoadControl(
          preferredForwardBufferDuration: FinampSettingsHelper.finampSettings.bufferDisableSizeConstraints
              ? FinampSettingsHelper.finampSettings.bufferDuration
              : null, // let system decide
        ),
      ),
      audioPipeline: audioPipeline,
    );
  }

  void _setupStreamCacheProgressTracking() {
    final cache = GetIt.instance<StreamCacheService>();
    _activeCurrentIndexStream.listen((index) {
      final currentSource = _player.sequenceState.currentSource;
      if (currentSource is LockCachingAudioSource) {
        final title = (currentSource.tag as FinampQueueItem?)?.item.title;
        cache.trackProgressOf(currentSource, title: title);
        unawaited(currentSource.cacheFile.then((file) => cache.prune(keep: file)).catchError((_) {}));
      } else {
        cache.stopTracking();
      }
    });
  }

  void _setupDurationReconciliation() {
    _activeDurationStream.listen((duration) {
      if (duration == null || duration == Duration.zero) return;
      final current = mediaItem.valueOrNull;
      if (current == null || current.duration == duration) return;
      if (current.extras?["downloadedTrackPath"] == null) return;

      final currentSourceTag = _player.sequenceState.currentSource?.tag as FinampQueueItem?;
      final currentTrackJson = current.extras?["itemJson"] as Map<String, dynamic>?;
      if (currentSourceTag == null || currentTrackJson == null) return;
      final displayedTrackId = jellyfin_models.BaseItemDto.fromJson(currentTrackJson).id;
      if (currentSourceTag.baseItem.id != displayedTrackId) return;

      mediaItem.add(current.copyWith(duration: duration));
    });
  }

  bool _crossfadeInProgress = false;

  void _setupCrossfade() {
    _activePositionStream.listen((position) async {
      final seconds = FinampSettingsHelper.finampSettings.crossfadeSeconds;
      if (seconds <= 0) return;
      if (_crossfadeInProgress) return;
      if (!_player.playing) return;

      final lastManualSeekAt = _lastManualSeekAt;
      if (lastManualSeekAt != null && DateTime.now().difference(lastManualSeekAt) < _crossfadeSeekGuardWindow) {
        return;
      }

      final duration = _player.duration;
      if (duration == null || duration == Duration.zero) return;

      if (duration.inSeconds < seconds * 2) return;

      if (!_player.hasNext) return;
      final toIndex = _player.nextIndex;
      if (toIndex == null) return;

      if (toIndex == _player.currentIndex) return;

      if (_standbyOutOfSync) {
        unawaited(_resyncStandby());
        return;
      }

      final remaining = duration - position;
      if (remaining <= Duration(seconds: seconds)) {
        await _performCrossfadeSwap(seconds: seconds, toIndex: toIndex);
      }
    });
  }

  Future<void> _abortCrossfadeIfInProgress() async {
    if (!_crossfadeInProgress) return;
    _crossfadeInProgress = false;
    await Future<void>.delayed(_audioFadeStepDuration);
    await _standbyVolume.setFadeVolume(1.0);
    await _standbyPlayer.pause();
  }

  Future<void> _performCrossfadeSwap({required int seconds, required int toIndex}) async {
    _crossfadeInProgress = true;
    final outgoingVolume = _volume;
    final incoming = _standbyPlayer;
    final incomingVolume = _standbyVolume;
    try {
      await incomingVolume.setFadeVolume(0.0);
      await incoming.seek(Duration.zero, index: toIndex);
      unawaited(incoming.play());

      final steps = getFadeSteps(Duration(seconds: seconds));
      for (var step = 1; step <= steps; step++) {
        if (!_crossfadeInProgress) return; // aborted — e.g. a manual skip
        final t = (step / steps).clamp(0.0, 1.0);
        await Future.wait([outgoingVolume.setFadeVolume(1.0 - t), incomingVolume.setFadeVolume(t)]);
        await Future<void>.delayed(_audioFadeStepDuration);
      }
      if (!_crossfadeInProgress) return;

      final outgoing = _player;
      await outgoing.pause();
      _activePlayerIndexSubject.add(1 - _activePlayerIndexSubject.value);
      await outgoingVolume.setFadeVolume(1.0); // reset ahead of its next turn as active
    } finally {
      _crossfadeInProgress = false;
    }
  }

  SleepTimer? get sleepTimer => _timer.value;

  /// this could be useful for updating queue state from this player class, but isn't used right now due to limitations with just_audio
  void setQueueCallbacks({required Future<bool> Function() previousTrackCallback}) {
    _queueCallbackPreviousTrack = previousTrackCallback;
  }

  bool get _crossfadeEnabled => FinampSettingsHelper.finampSettings.crossfadeSeconds > 0;

  bool _standbyOutOfSync = false;
  bool _standbyResyncing = false;

  Future<void> _mirrorToStandby(Future<void> Function(AudioPlayer) action) async {
    if (!_crossfadeEnabled) {
      _standbyOutOfSync = true;
      return;
    }
    try {
      await action(_standbyPlayer);
    } catch (e, stack) {
      _audioServiceBackgroundTaskLogger.warning("Failed to mirror a queue change to the standby player", e, stack);
    }
  }

  /// Rebuilds the standby player's queue from the active one, for when
  /// crossfade is switched on after queue changes were skipped.
  ///
  /// Only the order matters: a crossfade seeks the standby player by raw index,
  /// so its shuffle order does not have to match.
  Future<void> _resyncStandby() async {
    if (_standbyResyncing) return;
    _standbyResyncing = true;
    try {
      final queueItems = _player.audioSources
          .map((source) => (source as IndexedAudioSource).tag)
          .whereType<FinampQueueItem>()
          .toList();
      await _standbyPlayer.setAudioSources(
        await Future.wait(queueItems.map(_queueItemToAudioSource)),
        preload: false,
        initialIndex: _player.currentIndex,
      );
      _standbyOutOfSync = false;
    } catch (e, stack) {
      _audioServiceBackgroundTaskLogger.warning("Could not resync the standby player", e, stack);
    } finally {
      _standbyResyncing = false;
    }
  }

  Future<Duration?> setQueueItems(
    List<FinampQueueItem> queueItems, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    try {
      final result = await _player.setAudioSources(
        await Future.wait(queueItems.map(_queueItemToAudioSource)),
        preload: preload,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
        shuffleOrder: shuffleOrder,
      );
      unawaited(
        _mirrorToStandby(
          (player) async => player.setAudioSources(
            await Future.wait(queueItems.map(_queueItemToAudioSource)),
            preload: false,
            initialIndex: initialIndex,
            shuffleOrder: shuffleOrder,
          ),
        ),
      );
      return result;
    } on PlayerException catch (e) {
      _audioServiceBackgroundTaskLogger.severe("Player error code ${e.code}: ${e.message}");
      GlobalSnackbar.error(e);
    } on PlayerInterruptedException catch (e) {
      _audioServiceBackgroundTaskLogger.warning("Player interrupted: ${e.message}");
      GlobalSnackbar.error(e);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe("Player error ${e.toString()}");
      GlobalSnackbar.error(e);
    }
    return null;
  }

  Future<void> appendFinampQueueItem(FinampQueueItem queueItem) async {
    unawaited(_mirrorToStandby((player) async => player.addAudioSource(await _queueItemToAudioSource(queueItem))));
    return _player.addAudioSource(await _queueItemToAudioSource(queueItem));
  }

  Future<void> appendFinampQueueItems(List<FinampQueueItem> queueItems) async {
    unawaited(
      _mirrorToStandby(
        (player) async => player.addAudioSources(await Future.wait(queueItems.map(_queueItemToAudioSource))),
      ),
    );
    return _player.addAudioSources(await Future.wait(queueItems.map(_queueItemToAudioSource)));
  }

  Future<void> insertFinampQueueItemAt(int index, FinampQueueItem queueItem) async {
    unawaited(
      _mirrorToStandby((player) async => player.insertAudioSource(index, await _queueItemToAudioSource(queueItem))),
    );
    return _player.insertAudioSource(index, await _queueItemToAudioSource(queueItem));
  }

  Future<void> insertFinampQueueItems(int index, List<FinampQueueItem> queueItems) async {
    unawaited(
      _mirrorToStandby(
        (player) async => player.insertAudioSources(index, await Future.wait(queueItems.map(_queueItemToAudioSource))),
      ),
    );
    return _player.insertAudioSources(index, await Future.wait(queueItems.map(_queueItemToAudioSource)));
  }

  Future<void> moveFinampQueueItem(int currentIndex, int newIndex) {
    unawaited(_mirrorToStandby((player) => player.moveAudioSource(currentIndex, newIndex)));
    return _player.moveAudioSource(currentIndex, newIndex);
  }

  Future<void> removeFinampQueueItemAt(int index) {
    unawaited(_mirrorToStandby((player) => player.removeAudioSourceAt(index)));
    return _player.removeAudioSourceAt(index);
  }

  Future<void> removeFinampQueueItemRange(int start, int end) {
    unawaited(_mirrorToStandby((player) => player.removeAudioSourceRange(start, end)));
    return _player.removeAudioSourceRange(start, end);
  }

  Future<void> clearFinampQueueItems() {
    unawaited(_mirrorToStandby((player) => player.clearAudioSources()));
    return _player.clearAudioSources();
  }

  Future<void> dispose() => Future.wait([_playerA.dispose(), _playerB.dispose()]);

  @override
  Future<void> play({bool disableFade = false}) async {
    _audioServiceBackgroundTaskLogger.fine(
      "play() start: disableFade=$disableFade, playing=${_player.playing}, fadeDirection=${fadeState.value.fadeDirection}, currentIndex=${_player.currentIndex}, position=${_player.position}",
    );
    if (_shouldIgnorePlayPauseAfterRecentSkip) {
      return;
    }
    if (!disableFade && FinampSettingsHelper.finampSettings.audioFadeInDuration > Duration.zero) {
      return fadeInAndPlay();
    } else {
      await _volume.setFadeVolume(1.0);
      return _player.play();
    }
  }

  double get speed => _player.speed;

  @override
  Future<void> setSpeed(final double speed) async {
    return _player.setSpeed(speed);
  }

  Future<void> setPitch(final double pitch) async {
    return _player.setPitch(pitch);
  }

  void setVolume(final double volume) async {
    return _volume.setInternalVolume(volume);
  }

  @override
  Future<void> pause({bool disableFade = false}) async {
    _audioServiceBackgroundTaskLogger.fine(
      "pause() start: disableFade=$disableFade, playing=${_player.playing}, fadeDirection=${fadeState.value.fadeDirection}, currentIndex=${_player.currentIndex}, position=${_player.position}",
    );
    if (_shouldIgnorePlayPauseAfterRecentSkip) {
      return;
    }
    await _abortCrossfadeIfInProgress();
    if (!disableFade && FinampSettingsHelper.finampSettings.audioFadeOutDuration > Duration.zero) {
      return fadeOutAndPause();
    } else {
      return _player.pause();
    }
  }

  int getFadeSteps(Duration fadeDuration) {
    final steps = (fadeDuration.inMilliseconds / _audioFadeStepDuration.inMilliseconds).toInt();
    return steps < 1 ? 1 : steps;
  }

  double _getVolumeFadeInStepSize([Duration? overrideDuration]) {
    final steps = getFadeSteps(overrideDuration ?? FinampSettingsHelper.finampSettings.audioFadeInDuration);
    return 1.0 / steps;
  }

  double _getVolumeFadeOutStepSize([Duration? overrideDuration]) {
    final steps = getFadeSteps(overrideDuration ?? FinampSettingsHelper.finampSettings.audioFadeOutDuration);
    return 1.0 / steps;
  }

  int _fadeGeneration = 0;

  Future<void> _fadeAudio(FadeDirection direction, {bool pauseOnFadeOutComplete = true, Duration? fadeDuration}) async {
    final myGeneration = ++_fadeGeneration;

    fadeState.add(
      FadeState(
        fadeVolume: direction == FadeDirection.fadeIn ? 0.0 : 1.0,
        volumeFadeInStepSize: _getVolumeFadeInStepSize(fadeDuration),
        volumeFadeOutStepSize: _getVolumeFadeOutStepSize(fadeDuration),
        fadeDirection: direction,
      ),
    );

    // Prepare fade-in
    Future<void>? fut;
    if (direction == FadeDirection.fadeIn) {
      await _volume.setFadeVolume(0.0);
      fut = _player.play();
    }

    bool cancelled = false;
    await Stream.periodic(
      _audioFadeStepDuration,
      (_) => fadeState.value,
    ).takeWhile((fade) => fade.fadeDirection != FadeDirection.none && !cancelled).forEach((state) async {
      if (myGeneration != _fadeGeneration) {
        cancelled = true;
        return;
      }
      switch (state.fadeDirection) {
        case FadeDirection.fadeIn:
          var newVolume = state.fadeVolume + state.volumeFadeInStepSize;
          await _volume.setFadeVolume(newVolume);
          fadeState.add(state.copyWith(fadeVolume: newVolume));
          if (newVolume >= 1.0) {
            fadeState.add(state.copyWith(fadeDirection: FadeDirection.none));
            cancelled = true;
          }
          break;
        case FadeDirection.fadeOut:
          var newVolume = state.fadeVolume - state.volumeFadeOutStepSize;
          await _volume.setFadeVolume(newVolume);
          fadeState.add(state.copyWith(fadeVolume: newVolume));
          if (newVolume <= 0.0) {
            fadeState.add(state.copyWith(fadeDirection: FadeDirection.none));
            cancelled = true;

            if (pauseOnFadeOutComplete) {
              fut = _player.pause();
            }
          }
          break;
        default:
          break;
      }
    });

    return fut;
  }

  Future<void> fadeOutAndPause() async {
    switch (fadeState.value.fadeDirection) {
      case FadeDirection.fadeOut:
        return;
      case FadeDirection.fadeIn:
        // change fade direction
        fadeState.add(fadeState.value.copyWith(fadeDirection: FadeDirection.fadeOut));
        return;
      case FadeDirection.none:
        return _fadeAudio(FadeDirection.fadeOut);
    }
  }

  Future<void> fadeInAndPlay() async {
    switch (fadeState.value.fadeDirection) {
      case FadeDirection.fadeIn:
        return;
      case FadeDirection.fadeOut:
        // change fade direction
        fadeState.add(fadeState.value.copyWith(fadeDirection: FadeDirection.fadeIn));
        return;
      case FadeDirection.none:
        return _fadeAudio(FadeDirection.fadeIn);
    }
  }

  Future<void> togglePlayback() {
    if (_player.playing && fadeState.value.fadeDirection != FadeDirection.fadeOut) {
      return pause();
    } else {
      return play();
    }
  }

  @override
  Future<void> stop() async {
    try {
      _audioServiceBackgroundTaskLogger.info("Audio service received stop command");

      if (FinampSettingsHelper.finampSettings.clearQueueOnStopEvent) {
        await GetIt.instance<QueueService>().stopAndClearQueue();
      } else {
        // stop the player to release native assets but do not clear queue or reset playback state
        await stopPlayback();
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> stopPlayback() async {
    try {
      clearSleepTimer();
      await _abortCrossfadeIfInProgress();

      await _player.stop();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> handleEndOfQueue() async {
    try {
      _audioServiceBackgroundTaskLogger.info("Queue completed.");
      // A full stop will trigger a re-shuffle with an unshuffled first
      // item, so only pause.
      await pause(disableFade: true);
      if (FinampSettingsHelper.finampSettings.radioEnabled) {
        // Skipping to zero with empty queue re-triggers queue complete event
        // while radio is enable, we should never reach the end of the queue
        // if we end up reaching it, e.g. because the current radio mode becomes available (offline, etc.), we want to pause without resetting the queue, so that the user can fix the radio issue and resume, if desired.
        // Seek back a bit to avoid resetting the track to position zero when the queue is updated
        final seekBackTarget = playbackPosition - Duration(milliseconds: 500);
        await seek(seekBackTarget.isNegative ? Duration.zero : seekBackTarget);
      } else {
        if (_player.effectiveIndices.isNotEmpty) {
          await skipToIndex(0);
        }
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  int getPlayPositionInSeconds() {
    return _player.position.inSeconds;
  }

  @override
  Future<void> skipToPrevious({bool forceSkip = false}) async {
    _audioServiceBackgroundTaskLogger.fine(
      "skipToPrevious() start: forceSkip=$forceSkip, playing=${_player.playing}, fadeDirection=${fadeState.value.fadeDirection}, hasPrevious=${_player.hasPrevious}, loopMode=${_player.loopMode}, currentIndex=${_player.currentIndex}, position=${_player.position}",
    );
    _lastSkipCommandAt = DateTime.now();
    bool doSkip = true;

    _markManualSeek();
    await _abortCrossfadeIfInProgress();
    try {
      if (_queueCallbackPreviousTrack != null) {
        doSkip = await _queueCallbackPreviousTrack!();
      } else {
        doSkip = _player.position.inSeconds < 5;
      }

      // This can only be true if on first track while loop mode is off
      if (!_player.hasPrevious) {
        await _player.seek(Duration.zero);
      } else {
        if (doSkip || forceSkip) {
          if (_player.loopMode == LoopMode.one) {
            // if the user manually skips to the previous track, they probably want to actually skip to the previous track
            await skipByOffset(-1); //!!! don't use _player.previousIndex here, because that adjusts based on loop mode
          } else {
            await _player.seekToPrevious();
          }
        } else {
          await _player.seek(Duration.zero);
        }
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> skipToNext() async {
    _audioServiceBackgroundTaskLogger.fine(
      "skipToNext() start: playing=${_player.playing}, fadeDirection=${fadeState.value.fadeDirection}, hasNext=${_player.hasNext}, loopMode=${_player.loopMode}, currentIndex=${_player.currentIndex}, position=${_player.position}",
    );
    _lastSkipCommandAt = DateTime.now();
    _markManualSeek();
    await _abortCrossfadeIfInProgress();
    try {
      if (_player.loopMode == LoopMode.one || !_player.hasNext) {
        // if the user manually skips to the next track, they probably want to actually skip to the next track
        await skipByOffset(1); //!!! don't use _player.nextIndex here, because that adjusts based on loop mode
      } else {
        await _player.seekToNext();
      }
      _audioServiceBackgroundTaskLogger.finer("_player.nextIndex: ${_player.nextIndex}");
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> skipByOffset(int offset) async {
    _audioServiceBackgroundTaskLogger.fine("skipping by offset: $offset");

    _markManualSeek();
    await _abortCrossfadeIfInProgress();
    try {
      int queueIndex = _player.shuffleModeEnabled
          ? shuffleIndices.indexOf((_player.currentIndex ?? 0)) + offset
          : (_player.currentIndex ?? 0) + offset;
      if (queueIndex >= _player.effectiveIndices.length) {
        if (_player.loopMode == LoopMode.off) {
          //!!! seek to end of track to for the player to handle the end of queue
          // this is hacky, but seems to be the only way to get the proper events that the playback history service needs
          //TODO Finamp should probably use its own event system that is able to convey the necessary information
          return await _player.seek(_player.duration);
        }
        queueIndex %= (_player.effectiveIndices.length);
      }
      if (queueIndex < 0) {
        if (_player.loopMode == LoopMode.off) {
          queueIndex = 0;
        } else {
          queueIndex %= (_player.effectiveIndices.length);
        }
      }
      await _player.seek(Duration.zero, index: _player.shuffleModeEnabled ? shuffleIndices[queueIndex] : queueIndex);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> skipToIndex(int index) async {
    _audioServiceBackgroundTaskLogger.fine("skipping to index: $index");

    _markManualSeek();
    await _abortCrossfadeIfInProgress();
    try {
      await _player.seek(Duration.zero, index: _player.shuffleModeEnabled ? shuffleIndices[index] : index);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    _markManualSeek();
    await _abortCrossfadeIfInProgress();
    try {
      await _player.seek(position);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> shuffle() async {
    await _abortCrossfadeIfInProgress();
    try {
      await _player.shuffle();
      unawaited(_mirrorToStandby((player) => player.shuffle()));
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    try {
      switch (shuffleMode) {
        case AudioServiceShuffleMode.all:
          await _player.setShuffleModeEnabled(true);
          break;
        case AudioServiceShuffleMode.none:
          await _player.setShuffleModeEnabled(false);
          break;
        default:
          return Future.error(
            "Unsupported AudioServiceRepeatMode! Received ${shuffleMode.toString()}, requires all or none.",
          );
      }
      _audioServiceBackgroundTaskLogger.info("Set shuffle mode to $shuffleMode");
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    try {
      switch (repeatMode) {
        case AudioServiceRepeatMode.all:
          await _player.setLoopMode(LoopMode.all);
          break;
        case AudioServiceRepeatMode.none:
          await _player.setLoopMode(LoopMode.off);
          break;
        case AudioServiceRepeatMode.one:
          await _player.setLoopMode(LoopMode.one);
          break;
        default:
          return Future.error(
            "Unsupported AudioServiceRepeatMode! Received ${repeatMode.toString()}, requires all, none, or one.",
          );
      }
      _audioServiceBackgroundTaskLogger.info("Set repeat mode to $repeatMode");
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  /// Returns the top-level browsable categories for use in a media browser.
  List<MediaItem> _getRootMenu() {
    return [
      MediaItem(
        id: MediaItemId(contentType: ContentType.albums, parentType: MediaItemParentType.rootCollection).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.albums ?? ContentType.albums.toString(),
        playable: false,
      ),
      MediaItem(
        id: MediaItemId(
          contentType: ContentType.performingArtists,
          parentType: MediaItemParentType.rootCollection,
        ).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.artists ?? ContentType.performingArtists.toString(),
        playable: false,
      ),
      MediaItem(
        id: MediaItemId(contentType: ContentType.playlists, parentType: MediaItemParentType.rootCollection).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.playlists ?? ContentType.playlists.toString(),
        playable: false,
      ),
      MediaItem(
        id: MediaItemId(contentType: ContentType.genres, parentType: MediaItemParentType.rootCollection).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.genres ?? ContentType.genres.toString(),
        playable: false,
      ),
      MediaItem(
        id: MediaItemId(contentType: ContentType.tracks, parentType: MediaItemParentType.rootCollection).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.tracks ?? ContentType.tracks.toString(),
        playable: false,
      ),
    ];
  }

  /// Implements a media browser, like used in Android Auto.
  /// Called with the ID of a non-playable (and therefore browsable) [MediaItem], and returns a list of its children.
  /// We jerry-rig the [parentMediaId] to be a JSON string that can be parsed into a [MediaItemId] object, otherwise we don't have a way to tell which item the parentMediaId refers to.
  /// There are some special IDs that might be passed to this method:
  /// - [AudioService.browsableRootId] is passed when the client requests the root menu (the list of top-level categories)
  /// - [AudioService.recentRootId] is passed when the client requests the recent items (e.g. in the "For you" section of Android Auto).
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    // display root category/parent
    if (parentMediaId == AudioService.browsableRootId) {
      _appLocalizations ??= await AppLocalizations.delegate.load(
        FinampSettingsHelper.finampSettings.locale ?? const Locale("en", "US"),
      );

      return _getRootMenu();
    } else if (parentMediaId == AudioService.recentRootId) {
      // return await _androidAutoHelper.getRecentItems();
      // return playlists for now
      return await _androidAutoHelper.getMediaItems(
        MediaItemId(contentType: ContentType.playlists, parentType: MediaItemParentType.rootCollection),
      );
    } else {
      try {
        final itemId = MediaItemId.fromJson(jsonDecode(parentMediaId) as Map<String, dynamic>);

        return await _androidAutoHelper.getMediaItems(itemId);
      } catch (e) {
        _audioServiceBackgroundTaskLogger.severe(e);
        return super.getChildren(parentMediaId);
      }
    }
  }

  /// Called when a media item is requested to be played.
  /// We jerry-rig the [mediaId] to be a JSON string that can be parsed into a [MediaItemId] object, otherwise we don't have a way to tell which item the mediaId refers to.
  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    try {
      if (mediaId == QueueItemSourceNameType.shuffleAll.name) {
        return await _androidAutoHelper.shuffleAllTracks();
      }
      final mediaItemId = MediaItemId.fromJson(jsonDecode(mediaId) as Map<String, dynamic>);

      return await _androidAutoHelper.playFromMediaId(mediaItemId);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return super.playFromMediaId(mediaId, extras);
    }
  }

  /// Called when a media browser performs a search, e.g. using a search bar or to correct a voice search.
  /// Currently, the [extras] parameter isn't passed correctly by AudioService, so some of the metadata available during a voice search isn't available here, that's why we store the [lastSearchQuery] to use it here.
  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    _audioServiceBackgroundTaskLogger.info("search: $query ; extras: $extras");

    final previousItemTitle = _androidAutoHelper.lastSearchQuery?.extras?["android.intent.extra.title"] as String?;

    final currentSearchQuery = AndroidAutoSearchQuery(query, extras);

    if (previousItemTitle != null) {
      // when voice searching for a track with title + artist, Android Auto / Google Assistant combines the title and artist into a single query, with no way to differentiate them
      // so we try to instead use the title provided in the extras right after the voice search, and just search for that
      if (query.contains(previousItemTitle)) {
        // if the the title is fully contained in the query, we can assume that the user clicked on the "Search Results" button on the player screen
        currentSearchQuery.rawQuery = previousItemTitle;
        currentSearchQuery.extras = _androidAutoHelper.lastSearchQuery?.extras;
      } else {
        // otherwise, we assume they're searching for something else, and discard the previous search query
        _androidAutoHelper.setLastSearchQuery(null);
      }
    }

    final results = await _androidAutoHelper.searchItems(currentSearchQuery);
    return results;
  }

  /// Called when the user asks for an item to be played based on a query.
  /// In this case, the search needs to be performed and the "best" result should be played immediately.
  /// [extras] can contain additional information about the search, like the original query, a title, artist, or album (all optional and filled in by e.g. the Voice Assistant for popular items. Provided fields can indicate which type of item was requested).
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    _audioServiceBackgroundTaskLogger.info("playFromSearch: $query ; extras: $extras");
    final searchQuery = AndroidAutoSearchQuery(query, extras);
    _androidAutoHelper.setLastSearchQuery(searchQuery);
    await _androidAutoHelper.playFromSearch(searchQuery);
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    try {
      final action = CustomPlaybackActions.values.firstWhere((element) => element.name == name);
      switch (action) {
        case CustomPlaybackActions.shuffle:
          final queueService = GetIt.instance<QueueService>();
          return queueService.togglePlaybackOrder();
        case CustomPlaybackActions.radio:
          RadioServiceHelper.toggleRadio();
        case CustomPlaybackActions.toggleFavorite:
          return toggleFavoriteStatusOfCurrentTrack();
        case CustomPlaybackActions.dbusVolume:
          final volume = extras?["value"] as double?;
          if (volume != null) {
            _audioServiceBackgroundTaskLogger.info("Setting volume to $volume from dbus.");
            await _volume.setInternalVolume(volume);
          }
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe("Custom action '$name' not found.", e);
    }

    // only called if no custom action was found
    return await super.customAction(name, extras);
  }

  Future<void> toggleFavoriteStatusOfCurrentTrack() async {
    final ref = GetIt.instance<ProviderContainer>();
    jellyfin_models.BaseItemDto? currentItem;

    if (mediaItem.valueOrNull?.extras?["itemJson"] != null) {
      currentItem = jellyfin_models.BaseItemDto.fromJson(
        mediaItem.valueOrNull?.extras!["itemJson"] as Map<String, dynamic>,
      );
    } else {
      return;
    }

    bool isFavorite = currentItem.userData?.isFavorite ?? false;
    // get current favorite status from the provider
    isFavorite = ref.read(isFavoriteProvider(currentItem));
    // update favorite status with the value returned by the provider
    isFavorite = ref.read(isFavoriteProvider(currentItem).notifier).updateFavorite(!isFavorite);
    return refreshPlaybackStateAndMediaNotification();
  }

  Future<void> refreshPlaybackStateAndMediaNotification() async {
    // re-trigger the playbackState update to update the notification
    final event = _transformEvent(_player.playbackEvent);
    return playbackState.add(event);
  }

  // triggers when skipping to specific item in android auto queue
  @override
  Future<void> skipToQueueItem(int index) async {
    return skipToIndex(index);
  }

  void _applyVolumeNormalization(MediaItem? currentTrack) {
    if (FinampSettingsHelper.finampSettings.volumeNormalizationActive && currentTrack != null) {
      final baseItem = jellyfin_models.BaseItemDto.fromJson(currentTrack.extras?["itemJson"] as Map<String, dynamic>);

      double? effectiveGainChange = getGainForCurrentPlayback(currentTrack, baseItem);

      _volumeNormalizationLogger.info(
        "normalization gain for '${baseItem.name}': $effectiveGainChange (track gain change: ${baseItem.normalizationGain})",
      );
      if (effectiveGainChange != null) {
        if (_loudnessEnhancerEffect != null) {
          _loudnessEnhancerEffect?.setTargetGain(effectiveGainChange);
        } else {
          final newVolume =
              iosBaseVolumeGainFactor *
              pow(
                10.0,
                effectiveGainChange / 20.0,
              ); // https://sound.stackexchange.com/questions/38722/convert-db-value-to-linear-scale
          _volumeNormalizationLogger.finer("new volume: $newVolume");
          _volume.setReplayGainVolume(newVolume);
        }
      } else {
        if (_loudnessEnhancerEffect != null) {
          // reset gain offset
          _loudnessEnhancerEffect?.setTargetGain(0);
        }
        _volume.setReplayGainVolume(
          iosBaseVolumeGainFactor,
        ); //!!! it's important that the base gain is used instead of 1.0, so that any tracks without normalization gain information don't fall back to full volume, but to the base volume for iOS
      }
    }
  }

  /// Handles a sleep timer triggering, pausing play and clearing the timer
  void completeSleepTimer() {
    pause();
    _timer.value?.cancel();
    _timer.value = null;
    // stop playback reporting, since the playback is not expected to resume in the near future
    GetIt.instance<PlaybackHistoryService>().reportPlaybackStopped();
  }

  /// Starts the new sleep timer
  void startSleepTimer(SleepTimer newSleepTimer) {
    _timer.value = newSleepTimer;
    sleepTimer?.start(completeSleepTimer);
  }

  /// Cancels the sleep timer and clears it.
  void clearSleepTimer() {
    _timer.value?.cancel();
    _timer.value = null;
  }

  // Duration get sleepTimerRemaining {
  //   return sleepTimer.getRemaining();
  // }

  /// Transform a just_audio event into an audio_service state.
  ///
  /// This method is used from the constructor. Every event received from the
  /// just_audio player will be transformed into an audio_service state so that
  /// it can be broadcast to audio_service clients.
  PlaybackState _transformEvent(PlaybackEvent event) {
    jellyfin_models.BaseItemDto? currentItem;
    bool isFavorite = false;

    // Sync playback state to iOS for CarPlay Now Playing screen
    IosPlaybackStateSync.setPlaybackState(isPlaying: _player.playing);

    if (mediaItem.valueOrNull?.extras?["itemJson"] != null) {
      currentItem = jellyfin_models.BaseItemDto.fromJson(
        mediaItem.valueOrNull?.extras!["itemJson"] as Map<String, dynamic>,
      );
      isFavorite = GetIt.instance<ProviderContainer>().read(isFavoriteProvider(currentItem));
    }

    final radioEnabled = FinampSettingsHelper.finampSettings.radioEnabled;
    final radioActive = GetIt.instance<ProviderContainer>()
        .read(RadioServiceHelper.currentRadioAvailabilityStatusProvider)
        .isAvailable;

    var reportedPosition = _player.position;
    final trackDuration = _player.duration;
    if (trackDuration != null && trackDuration > Duration.zero && reportedPosition > trackDuration) {
      reportedPosition = trackDuration;
    }

    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        if (FinampSettingsHelper.finampSettings.showFavoriteButtonOnMediaNotification &&
            !FinampSettingsHelper.finampSettings.isOffline)
          MediaControl.custom(
            name: CustomPlaybackActions.toggleFavorite.name,
            androidIcon: isFavorite ? "drawable/baseline_heart_filled_24" : "drawable/baseline_heart_24",
            label: isFavorite ? GlobalSnackbar.requireL10n.removeFavorite : GlobalSnackbar.requireL10n.addFavorite,
          ),
        if (FinampSettingsHelper.finampSettings.showShuffleButtonOnMediaNotification)
          //TODO eventually we probably want separate settings for this, and not store them as individual booleans in Hive
          radioEnabled
              ? MediaControl.custom(
                  name: CustomPlaybackActions.radio.name,
                  androidIcon: radioActive ? "drawable/tabler_icons_radio_24" : "drawable/tabler_icons_radio_off_24",
                  label: radioActive
                      ? GlobalSnackbar.requireL10n.radioModeActiveTitle
                      : GlobalSnackbar.requireL10n.radioModeInactiveTitle,
                )
              : MediaControl.custom(
                  name: CustomPlaybackActions.shuffle.name,
                  androidIcon: _player.shuffleModeEnabled
                      ? "drawable/baseline_shuffle_on_24"
                      : "drawable/baseline_shuffle_24",
                  label: _player.shuffleModeEnabled
                      ? GlobalSnackbar.requireL10n.playbackOrderShuffledButtonLabel
                      : GlobalSnackbar.requireL10n.playbackOrderLinearButtonLabel,
                ),
        if (FinampSettingsHelper.finampSettings.showStopButtonOnMediaNotification)
          MediaControl.stop.copyWith(androidIcon: "drawable/baseline_stop_24"),
      ],
      systemActions: FinampSettingsHelper.finampSettings.showSeekControlsOnMediaNotification
          ? const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward}
          : {},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      //!!! use the current player position, since there might be a delay before this event is processed.
      // Do **not** use [event.updatePosition] or [event.bufferedPosition], since that could lead to a discontinuity in the playback position (resetting to 0) and cause incorrect history entries
      updatePosition: reportedPosition,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.shuffleModeEnabled && shuffleIndices.isNotEmpty && event.currentIndex != null
          ? shuffleIndices.indexOf(event.currentIndex!)
          : event.currentIndex,
      shuffleMode: _player.shuffleModeEnabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: _audioServiceRepeatMode(_player.loopMode),
    );
  }

  int? get queueIndex => _player.shuffleModeEnabled && shuffleIndices.isNotEmpty && _player.currentIndex != null
      ? shuffleIndices.indexOf(_player.currentIndex!)
      : _player.currentIndex;
  SequenceState get sequenceState => _player.sequenceState;
  double get volume => (_volume._internalVolume * 100).roundToDouble() / 100;
  bool get paused => !_player.playing;
  Duration get playbackPosition => _player.position;

  void onQueueServiceAvailable() {
    // Moved here because currentTrackMetadataProvider depends on queueService
    // If metadataProvider is sloooooow, this allows it to catch up
    GetIt.instance<ProviderContainer>().listen(currentTrackMetadataProvider, (previous, next) {
      // update media notification to reflect favorite state
      refreshPlaybackStateAndMediaNotification();

      if (FinampSettingsHelper.finampSettings.volumeNormalizationMode != VolumeNormalizationMode.albumBased &&
          FinampSettingsHelper.finampSettings.volumeNormalizationMode != VolumeNormalizationMode.hybrid) {
        return;
      }
      if (previous?.valueOrNull?.parentNormalizationGain != next.valueOrNull?.parentNormalizationGain) {
        _applyVolumeNormalization(mediaItem.valueOrNull);
      }
    });
  }

  /// Syncs the list of MediaItems (_queue) with the internal queue of the player.
  /// Called by onAddQueueItem and onUpdateQueue.
  Future<AudioSource> _queueItemToAudioSource(FinampQueueItem queueItem) async {
    if (queueItem.item.extras!["downloadedTrackPath"] == null) {
      // If downloadedTrack wasn't passed, we assume that the item is not
      // downloaded.

      // If offline, we throw an error so that we don't accidentally stream from
      // the internet. See the big comment in _trackUri() to see why this was
      // passed in extras.
      if (queueItem.item.extras!["isOffline"] as bool) {
        return Future.error("Offline mode enabled but downloaded track not found.");
      } else {
        final source = await _resolveStream(queueItem.item);
        final headers = source.headers.isEmpty ? null : source.headers;

        final transcoding = queueItem.item.extras!["shouldTranscode"] as bool;
        final isYouTube = queueItem.baseItemId.sourceId == YouTubeService.sourceId;
        final cache = GetIt.instance<StreamCacheService>();

        // Runs once per track in the queue, so keep it off the default level.
        _audioServiceBackgroundTaskLogger.finer(
          "_queueItemToAudioSource: '${queueItem.item.title}' transcoding=$transcoding "
          "container=${queueItem.baseItem.container}",
        );
        if (isYouTube && !source.isLocalFile) {
          try {
            final file = await cache.fileForId(queueItem.baseItemId.raw, source.container ?? "m4a");
            return LockCachingAudioSource(source.uri, cacheFile: file, headers: headers, tag: queueItem);
          } catch (e, stack) {
            _audioServiceBackgroundTaskLogger.warning(
              "Could not prepare '${queueItem.item.title}' for playback",
              e,
              stack,
            );
            return Future.error(e);
          }
        }

        if (cache.enabled && !transcoding && !source.isLocalFile) {
          try {
            final item = jellyfin_models.BaseItemDto.fromJson(
              queueItem.item.extras!["itemJson"] as Map<String, dynamic>,
            );
            final cacheFile = await cache.fileFor(item);
            return LockCachingAudioSource(source.uri, cacheFile: cacheFile, headers: headers, tag: queueItem);
          } catch (e, stack) {
            _audioServiceBackgroundTaskLogger.warning(
              "Could not cache '${queueItem.item.title}'; streaming it",
              e,
              stack,
            );
          }
        }

        return AudioSource.uri(source.uri, headers: headers, tag: queueItem);
      }
    } else {
      // We have to deserialise this because Dart is stupid and can't handle
      // sending classes through isolates.
      final downloadedTrackPath = queueItem.item.extras!["downloadedTrackPath"] as String;

      // Path verification and stuff is done in AudioServiceHelper, so this path
      // should be valid.
      final downloadUri = Uri.file(downloadedTrackPath);
      return AudioSource.uri(downloadUri, tag: queueItem);
    }
  }

  Future<PlayableSource> _resolveStream(MediaItem mediaItem) async {
    final item = jellyfin_models.BaseItemDto.fromJson(mediaItem.extras!["itemJson"] as Map<String, dynamic>);
    final backend = GetIt.instance<BackendRegistry>().backendFor(item);
    return backend.resolveStream(
      item,
      transcode: mediaItem.extras!["shouldTranscode"] as bool,
      playSessionId: mediaItem.extras!["playSessionId"] as String?,
    );
  }

  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> addQueueItem(MediaItem mediaItem) async {}
  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {}
  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {}
  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> updateQueue(List<MediaItem> queue) async {}
  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> updateMediaItem(MediaItem mediaItem) async {}
  @override
  @Deprecated(
    "Don't use this method, we're using methods based on FinampQueueItem. This implementation is just for best-effort platform compatibility.",
  )
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final index = queue.valueOrNull?.indexOf(mediaItem);
    if (index != null) {
      return removeFinampQueueItemAt(index);
    }
  }

  @override
  @Deprecated(
    "Don't use this method, we're using methods based on FinampQueueItem. This implementation is just for best-effort platform compatibility.",
  )
  Future<void> removeQueueItemAt(int index) async {
    return removeFinampQueueItemAt(index);
  }

  @override
  @Deprecated(
    "Don't use this method, we're using methods based on FinampQueueItem. This implementation is just for best-effort platform compatibility.",
  )
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) async {
    jellyfin_models.BaseItemDto? currentItem;

    if (mediaItem.valueOrNull?.extras?["itemJson"] != null) {
      currentItem = jellyfin_models.BaseItemDto.fromJson(
        mediaItem.valueOrNull?.extras!["itemJson"] as Map<String, dynamic>,
      );
    } else {
      return;
    }
    bool isFavorite = currentItem.userData?.isFavorite ?? false;
    switch (rating.getRatingStyle()) {
      case RatingStyle.heart:
        if (rating.hasHeart() && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (!rating.hasHeart() && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.thumbUpDown:
        if (rating.isThumbUp() && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (!rating.isThumbUp() && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.percentage:
        final percentage = rating.getPercentRating();
        if (percentage > 0.5 && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (percentage < 0.5 && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.range3stars:
        final stars = rating.getStarRating();
        if (stars >= 1.5 && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (stars <= 0.5 && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.range4stars:
        final stars = rating.getStarRating();
        if (stars >= 2.0 && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (stars <= 1.0 && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.range5stars:
        final stars = rating.getStarRating();
        if (stars >= 3 && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (stars <= 2.0 && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      default:
      // do nothing
    }
  }

  @override
  @Deprecated("Don't use this method yet, it has no implementation")
  Future<void> setCaptioningEnabled(bool enabled) async {}
}

double? getGainForCurrentPlayback(MediaItem currentTrack, jellyfin_models.BaseItemDto? item) {
  final baseItem =
      item ?? jellyfin_models.BaseItemDto.fromJson(currentTrack.extras?["itemJson"] as Map<String, dynamic>);

  double? effectiveGainChange;
  final providerContainer = GetIt.instance<ProviderContainer>();
  providerContainer.read(
    currentTrackMetadataProvider,
  ); // forces it even in background https://github.com/rrousselGit/riverpod/issues/2671

  switch (FinampSettingsHelper.finampSettings.volumeNormalizationMode) {
    case VolumeNormalizationMode.hybrid
        when GetIt.instance<QueueService>().getQueue().isCurrentlyPlayingTracksFromSameAlbum():
    case VolumeNormalizationMode.albumBased:
      // final parentNormalizationGain = providerContainer.read(currentTrackMetadataProvider).valueOrNull?.parentNormalizationGain;
      // includeLyrics is always true - fetch the metadataRequest directly.
      // Requires that provided arguments are the only fields of request,
      // along with `includeLyrics` always being true in currentTrackMetadataProvider
      // Otherwise, use code commented above
      final parentNormalizationGain = providerContainer
          .read(metadataProvider(baseItem))
          .valueOrNull
          ?.parentNormalizationGain;

      effectiveGainChange =
          parentNormalizationGain ??
          (currentTrack.extras?["contextNormalizationGain"] as double?) ??
          baseItem.normalizationGain;
      break;
    case VolumeNormalizationMode.hybrid:
    case VolumeNormalizationMode.trackBased:
      effectiveGainChange = baseItem.normalizationGain;
      break;
    case VolumeNormalizationMode.albumOnly:
      // only ever use context normalization gain, don't normalize tracks out of special contexts
      effectiveGainChange = currentTrack.extras?["contextNormalizationGain"] as double?;
      break;
  }
  return effectiveGainChange;
}

AudioServiceRepeatMode _audioServiceRepeatMode(LoopMode loopMode) {
  switch (loopMode) {
    case LoopMode.off:
      return AudioServiceRepeatMode.none;
    case LoopMode.one:
      return AudioServiceRepeatMode.one;
    case LoopMode.all:
      return AudioServiceRepeatMode.all;
  }
}
