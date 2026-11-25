import 'dart:async';

import 'package:collection/collection.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/hifi/hifi_platform.dart';
import 'package:diapason/services/hifi/mpv_output.dart';
import 'package:diapason/services/hifi/native_output.dart';
import 'package:diapason/services/hifi/signal_path.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:logging/logging.dart';

/// Source format as far as the server's metadata says.
class SourceFormat {
  const SourceFormat({this.codec, this.container, this.sampleRate, this.bitDepth, this.channels});

  final String? codec;
  final String? container;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;

  static SourceFormat of(BaseItemDto item) {
    final source = item.mediaSources?.firstOrNull;
    final stream = source?.mediaStreams.firstWhereOrNull((s) => s.type == "Audio") ?? source?.mediaStreams.firstOrNull;
    return SourceFormat(
      codec: stream?.codec,
      container: source?.container ?? item.container,
      sampleRate: stream?.sampleRate,
      bitDepth: stream?.bitDepth,
      channels: stream?.channels,
    );
  }
}

/// Bit-perfect output: applies the setting to the platform output and reports what the output does.
class HifiService {
  HifiService._();

  static final instance = HifiService._();
  static final _log = Logger("HifiService");

  HifiBackend get backend => currentHifiBackend;
  bool get supported => backend != HifiBackend.none;

  bool get bitPerfectActive => supported && FinampSettingsHelper.finampSettings.hifiBitPerfect;
  bool get exclusive => FinampSettingsHelper.finampSettings.hifiExclusive;
  String get dsdMode => FinampSettingsHelper.finampSettings.hifiDsdMode;
  String get outputDevice => FinampSettingsHelper.finampSettings.hifiOutputDevice;

  /// The last answer of the native side for this track (macOS device state, Android mixer), for the panel.
  Map<String, dynamic>? lastNative;
  SourceFormat? _lastFormat;

  bool _initialised = false;
  (bool, bool, String)? _applied;

  /// Hooks the mpv players and follows the settings. Call before the players are built.
  void init() {
    if (_initialised) return;
    _initialised = true;
    if (backend == HifiBackend.mpv) {
      // With pitch control on, media_kit sets speed through a `scaletempo` filter even at 1×; without it, through
      // mpv's `speed`, which leaves the samples alone at 1×. Read when the players are built (next launch).
      if (bitPerfectActive) JustAudioMediaKit.pitch = false;
      JustAudioMediaKit.onPlayerReady = (player) {
        unawaited(
          MpvHifiOutput.apply(player, bitPerfect: bitPerfectActive, exclusive: exclusive, device: outputDevice),
        );
      };
    }
    _applied = (bitPerfectActive, exclusive, outputDevice);
    FinampSettingsHelper.finampSettingsListener.addListener(() {
      final now = (bitPerfectActive, exclusive, outputDevice);
      if (now == _applied) return;
      _applied = now;
      unawaited(apply());
    });
  }

  /// Applies the current settings to the output now.
  Future<void> apply() async {
    _log.info("Bit-perfect ${bitPerfectActive ? "on" : "off"} (exclusive: $exclusive, device: '$outputDevice')");
    switch (backend) {
      case HifiBackend.mpv:
        await MpvHifiOutput.applyAll(bitPerfect: bitPerfectActive, exclusive: exclusive, device: outputDevice);
      case HifiBackend.coreAudio:
      case HifiBackend.androidMixer:
        if (bitPerfectActive) {
          final format = _lastFormat;
          if (format != null) await onTrackChanged(format);
        } else {
          lastNative = null;
          await NativeHifiOutput.clear();
        }
      case HifiBackend.none:
        break;
    }
  }

  /// Matches the output to a new track's format (macOS rate/hog, Android mixer). mpv opens its output at the
  /// track's rate by itself.
  Future<void> onTrackChanged(SourceFormat format) async {
    _lastFormat = format;
    if (!bitPerfectActive) return;
    final rate = format.sampleRate;
    switch (backend) {
      case HifiBackend.coreAudio:
        lastNative = await NativeHifiOutput.prepareCoreAudio(rate: rate ?? 0, exclusive: exclusive);
      case HifiBackend.androidMixer:
        if (rate == null) {
          lastNative = null;
          return;
        }
        // ExoPlayer hands the framework 16-bit PCM (its default); the mixer must match that format exactly.
        lastNative = await NativeHifiOutput.setAndroidBitPerfect(rate: rate, encoding: "pcm16");
        if (lastNative == null) _log.info("No bit-perfect mixer for $rate Hz/16-bit on this device");
      case HifiBackend.mpv:
        // media_kit rewrites `af` (scaletempo) whenever the speed is set: take it out again.
        await MpvHifiOutput.applyAll(bitPerfect: true, exclusive: exclusive, device: outputDevice);
      case HifiBackend.none:
        break;
    }
  }

  /// What the output does right now.
  Future<SignalOutput> readOutput({int? sourceRate}) async {
    switch (backend) {
      case HifiBackend.mpv:
        final mpv = await MpvHifiOutput.read();
        if (mpv == null) return const SignalOutput(backend: HifiBackend.mpv, api: "mpv");
        return SignalOutput(
          backend: backend,
          api: mpv.ao,
          device: mpv.device,
          sampleRate: mpv.outRate,
          format: mpv.outFormat,
          exclusive: mpv.exclusive,
          resampled: mpv.resampled,
          filters: mpv.filters,
        );
      case HifiBackend.coreAudio:
        final device = bitPerfectActive
            ? (lastNative ?? await NativeHifiOutput.outputDevice())
            : await NativeHifiOutput.outputDevice();
        final rate = (device?["rate"] as num?)?.round();
        return SignalOutput(
          backend: backend,
          api: "CoreAudio",
          device: device?["name"] as String?,
          sampleRate: rate,
          bitDepth: (device?["bits"] as num?)?.toInt(),
          exclusive: device?["hog"] as bool?,
          resampled: rate == null || sourceRate == null ? null : rate != sourceRate,
        );
      case HifiBackend.androidMixer:
        final device = await NativeHifiOutput.outputDevice();
        final mixer = bitPerfectActive ? lastNative : null;
        final rate = (mixer?["rate"] as num?)?.toInt();
        return SignalOutput(
          backend: backend,
          api: "AudioTrack",
          device: device?["name"] as String?,
          sampleRate: rate,
          format: mixer?["encoding"] as String?,
          exclusive: mixer != null,
          bitPerfectMixer: mixer?["bitPerfect"] as bool?,
          decoderBits: 16,
          resampled: rate == null || sourceRate == null ? null : rate != sourceRate,
        );
      case HifiBackend.none:
        return const SignalOutput(backend: HifiBackend.none, api: "AVAudioSession", exclusive: false);
    }
  }
}
