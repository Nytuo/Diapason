import 'package:diapason/services/hifi/dsd_audio_source.dart';
import 'package:diapason/services/hifi/hifi_platform.dart';

/// Why the output is not bit-perfect.
enum SignalPathIssue {
  /// iOS/tvOS: AVAudioSession resamples and mixes.
  platform,

  /// Bit-perfect mode is off.
  modeOff,

  /// The server transcodes the track.
  transcoded,

  /// DSD converted to PCM (here or by the player).
  dsdConverted,

  /// The output runs at another rate than the source.
  resampled,
  volume,
  replayGain,
  equalizer,
  crossfade,
  speed,

  /// The OS mixer is in the path (no exclusive access).
  sharedMixer,

  /// mpv runs a filter (`af`) on the samples.
  playerFilters,

  /// Android: the player decodes to 16-bit, the source has more.
  decoderDepth,

  /// Android: no USB DAC, Android < 14, or the DAC has no bit-perfect mixer at this format.
  noBitPerfectMixer,
}

enum SignalPathVerdict {
  bitPerfect,

  /// No resampling and unity gain, but through a float mixer that is not proven bit-exact (macOS).
  transparent,
  notBitPerfect,

  /// The output did not say what it runs at.
  unknown,
}

class SignalSource {
  const SignalSource({
    this.codec,
    this.container,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.transcoded = false,
    this.dsd,
  });

  final String? codec;
  final String? container;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;
  final bool transcoded;
  final DsdTrackInfo? dsd;
}

/// Stages that change samples, as they stand for this track.
class SignalProcessing {
  const SignalProcessing({
    this.volume = 1.0,
    this.replayGain = false,
    this.equalizer = false,
    this.crossfade = false,
    this.speed = 1.0,
  });

  final double volume;
  final bool replayGain;
  final bool equalizer;
  final bool crossfade;
  final double speed;
}

class SignalOutput {
  const SignalOutput({
    required this.backend,
    this.api,
    this.device,
    this.sampleRate,
    this.format,
    this.bitDepth,
    this.exclusive,
    this.resampled,
    this.bitPerfectMixer,
    this.decoderBits,
    this.filters,
  });

  final HifiBackend backend;

  /// `alsa`, `wasapi`, `CoreAudio`, `AAudio`…
  final String? api;
  final String? device;
  final int? sampleRate;

  /// mpv sample format (`s32`, `floatp`…) or an Android encoding (`pcm16`).
  final String? format;
  final int? bitDepth;
  final bool? exclusive;
  final bool? resampled;

  /// Android: the bit-perfect mixer the framework accepted (null: none).
  final bool? bitPerfectMixer;

  /// Android: bits per sample the player hands the framework.
  final int? decoderBits;

  /// mpv: the `af` filter chain, empty when none.
  final String? filters;
}

class SignalPath {
  SignalPath({required this.source, required this.processing, required this.output, required this.bitPerfectMode}) {
    _evaluate();
  }

  final SignalSource source;
  final SignalProcessing processing;
  final SignalOutput output;
  final bool bitPerfectMode;

  final List<SignalPathIssue> issues = [];
  late final SignalPathVerdict verdict;

  void _evaluate() {
    final backend = output.backend;
    if (backend == HifiBackend.none) issues.add(SignalPathIssue.platform);
    if (!bitPerfectMode && backend != HifiBackend.none) issues.add(SignalPathIssue.modeOff);
    if (source.transcoded) issues.add(SignalPathIssue.transcoded);
    final dsd = source.dsd;
    if (dsd != null && dsd.delivery != DsdDelivery.dop) issues.add(SignalPathIssue.dsdConverted);
    if (processing.volume < 0.999) issues.add(SignalPathIssue.volume);
    if (processing.replayGain) issues.add(SignalPathIssue.replayGain);
    if (processing.equalizer) issues.add(SignalPathIssue.equalizer);
    if (processing.crossfade) issues.add(SignalPathIssue.crossfade);
    if ((processing.speed - 1.0).abs() > 0.001) issues.add(SignalPathIssue.speed);
    if (output.resampled ?? false) issues.add(SignalPathIssue.resampled);
    switch (backend) {
      case HifiBackend.mpv:
        if (output.filters?.isNotEmpty ?? false) issues.add(SignalPathIssue.playerFilters);
        final direct = output.device?.startsWith("alsa/hw:") ?? false;
        if (!(output.exclusive ?? false) && !direct) issues.add(SignalPathIssue.sharedMixer);
      case HifiBackend.androidMixer:
        if (output.bitPerfectMixer != true) {
          issues.add(SignalPathIssue.noBitPerfectMixer);
        } else if ((source.bitDepth ?? 16) > (output.decoderBits ?? 16) && dsd == null) {
          issues.add(SignalPathIssue.decoderDepth);
        }
      case HifiBackend.coreAudio:
      case HifiBackend.none:
        break;
    }
    if (issues.isNotEmpty) {
      verdict = SignalPathVerdict.notBitPerfect;
    } else if (output.resampled == null) {
      verdict = SignalPathVerdict.unknown;
    } else if (backend == HifiBackend.coreAudio) {
      verdict = SignalPathVerdict.transparent;
    } else {
      verdict = SignalPathVerdict.bitPerfect;
    }
  }
}
