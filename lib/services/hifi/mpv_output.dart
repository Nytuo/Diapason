import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:logging/logging.dart';

/// What mpv reports about one player's audio chain.
class MpvOutputState {
  const MpvOutputState({
    this.ao,
    this.device,
    this.codec,
    this.inFormat,
    this.inRate,
    this.inChannels,
    this.outFormat,
    this.outRate,
    this.outChannels,
    this.filters,
    this.volume,
    this.exclusive,
  });

  /// `alsa`, `pulse`, `pipewire`, `wasapi`…
  final String? ao;
  final String? device;
  final String? codec;

  /// After the decoder (`audio-params`).
  final String? inFormat;
  final int? inRate;
  final int? inChannels;

  /// What the audio output was opened with (`audio-out-params`).
  final String? outFormat;
  final int? outRate;
  final int? outChannels;

  /// `af`: the user filter chain (empty when none).
  final String? filters;
  final double? volume;
  final bool? exclusive;

  bool? get resampled => inRate == null || outRate == null ? null : inRate != outRate;
}

/// Bit-perfect settings for the libmpv players (Linux, Windows), through the vendored just_audio_media_kit hook.
class MpvHifiOutput {
  static final _log = Logger("MpvHifiOutput");

  /// mpv properties for bit-perfect output: no user filters (media_kit puts `scaletempo` there for speed), unity
  /// volume, no ReplayGain, no forced rate/format/channel layout, and the device for this process alone.
  ///
  /// Turned off, the device is shared again and pitch correction comes back when media_kit is not doing it itself
  /// ([mediaKitPitch]: its `scaletempo` path, which wants mpv's own correction off).
  static Map<String, String> properties({
    required bool bitPerfect,
    required bool exclusive,
    required String device,
    bool mediaKitPitch = true,
  }) {
    if (!bitPerfect) {
      return {"audio-exclusive": "no", "audio-device": "auto", "audio-pitch-correction": mediaKitPitch ? "no" : "yes"};
    }
    return {
      "af": "",
      "audio-pitch-correction": "no",
      "replaygain": "no",
      "volume": "100",
      "mute": "no",
      "audio-samplerate": "0",
      "audio-format": "",
      "audio-channels": "auto",
      "audio-normalize-downmix": "no",
      "audio-exclusive": exclusive ? "yes" : "no",
      "audio-device": device.isEmpty ? "auto" : device,
    };
  }

  static Future<void> apply(
    Player player, {
    required bool bitPerfect,
    required bool exclusive,
    required String device,
  }) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    final props = properties(
      bitPerfect: bitPerfect,
      exclusive: exclusive,
      device: device,
      mediaKitPitch: JustAudioMediaKit.pitch,
    );
    for (final entry in props.entries) {
      try {
        // Dynamic call: media_kit's web stub of NativePlayer has no property API (this never runs on the web).
        await (native as dynamic).setProperty(entry.key, entry.value);
      } catch (e) {
        _log.warning("Could not set mpv ${entry.key}=${entry.value}: $e");
      }
    }
  }

  static Future<void> applyAll({required bool bitPerfect, required bool exclusive, required String device}) async {
    for (final player in JustAudioMediaKit.players) {
      await apply(player, bitPerfect: bitPerfect, exclusive: exclusive, device: device);
    }
  }

  /// The player that is playing, else the first one.
  static Player? get activePlayer {
    final players = JustAudioMediaKit.players.toList();
    if (players.isEmpty) return null;
    return players.where((p) => p.state.playing).firstOrNull ?? players.first;
  }

  static List<AudioDevice> devices() => activePlayer?.state.audioDevices ?? const [];

  static Future<MpvOutputState?> read() async {
    final player = activePlayer;
    final native = player?.platform;
    if (player == null || native is! NativePlayer) return null;
    Future<String?> get(String name) async {
      try {
        final value = await (native as dynamic).getProperty(name) as String;
        return value.isEmpty ? null : value;
      } catch (_) {
        return null;
      }
    }

    return MpvOutputState(
      ao: await get("current-ao"),
      device: await get("audio-device"),
      codec: await get("audio-codec-name"),
      inFormat: await get("audio-params/format"),
      inRate: int.tryParse(await get("audio-params/samplerate") ?? ""),
      inChannels: int.tryParse(await get("audio-params/channel-count") ?? ""),
      outFormat: await get("audio-out-params/format"),
      outRate: int.tryParse(await get("audio-out-params/samplerate") ?? ""),
      outChannels: int.tryParse(await get("audio-out-params/channel-count") ?? ""),
      filters: await get("af") ?? "",
      volume: double.tryParse(await get("volume") ?? ""),
      exclusive: switch (await get("audio-exclusive")) {
        "yes" => true,
        "no" => false,
        _ => null,
      },
    );
  }
}
