import 'package:diapason/services/hifi/dsd_audio_source.dart';
import 'package:diapason/services/hifi/hifi_platform.dart';
import 'package:diapason/services/hifi/mpv_output.dart';
import 'package:diapason/services/hifi/signal_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("DSD delivery", () {
    DsdDelivery choose(
      HifiBackend backend, {
      bool bitPerfect = true,
      String mode = "dop",
      bool dst = false,
      int channels = 2,
      bool sacd = false,
    }) => chooseDsdDelivery(
      backend: backend,
      bitPerfect: bitPerfect,
      dsdMode: mode,
      dst: dst,
      channels: channels,
      sacd: sacd,
    );

    test("DoP only on mpv, bit-perfect, stereo, and when asked", () {
      expect(choose(HifiBackend.mpv), DsdDelivery.dop);
      expect(choose(HifiBackend.mpv, bitPerfect: false), DsdDelivery.native);
      expect(choose(HifiBackend.mpv, mode: "pcm"), DsdDelivery.native);
      expect(choose(HifiBackend.mpv, channels: 6), DsdDelivery.native);
      expect(choose(HifiBackend.mpv, bitPerfect: false, sacd: true), DsdDelivery.pcm);
    });

    test("the other platforms convert to PCM", () {
      for (final backend in [HifiBackend.coreAudio, HifiBackend.androidMixer, HifiBackend.none]) {
        expect(choose(backend), DsdDelivery.pcm);
      }
    });

    test("DST plays only where ffmpeg decodes it", () {
      expect(choose(HifiBackend.mpv, dst: true), DsdDelivery.native);
      expect(choose(HifiBackend.mpv, dst: true, sacd: true), DsdDelivery.dstWrapped);
      expect(() => choose(HifiBackend.androidMixer, dst: true), throwsA(isA<DsdUnsupportedException>()));
    });

    test("a SACD image track is named by the URI fragment", () {
      expect(sacdTrackOf(Uri.file("/music/disc.iso").replace(fragment: "sacd=4")), 4);
      expect(sacdTrackOf(Uri.file("/music/a.dsf")), isNull);
    });
  });

  group("mpv properties", () {
    test("bit-perfect clears filters, holds unity volume and turns ReplayGain off", () {
      final props = MpvHifiOutput.properties(bitPerfect: true, exclusive: true, device: "alsa/hw:1,0");
      expect(props["af"], "");
      expect(props["volume"], "100");
      expect(props["replaygain"], "no");
      expect(props["audio-exclusive"], "yes");
      expect(props["audio-device"], "alsa/hw:1,0");
      expect(props["audio-samplerate"], "0");
    });

    test("turning it off gives the device back", () {
      final props = MpvHifiOutput.properties(bitPerfect: false, exclusive: true, device: "alsa/hw:1,0");
      expect(props["audio-exclusive"], "no");
      expect(props["audio-device"], "auto");
      expect(props["audio-pitch-correction"], "no");
      final noMediaKitPitch = MpvHifiOutput.properties(
        bitPerfect: false,
        exclusive: true,
        device: "",
        mediaKitPitch: false,
      );
      expect(noMediaKitPitch["audio-pitch-correction"], "yes");
    });
  });

  group("signal path verdict", () {
    const flac = SignalSource(codec: "flac", sampleRate: 96000, bitDepth: 24, channels: 2);

    test("mpv exclusive at the source rate with nothing in the way is bit-perfect", () {
      final path = SignalPath(
        source: flac,
        processing: const SignalProcessing(),
        output: const SignalOutput(backend: HifiBackend.mpv, exclusive: true, resampled: false),
        bitPerfectMode: true,
      );
      expect(path.verdict, SignalPathVerdict.bitPerfect);
    });

    test("a resampled output is not, whatever the mode", () {
      final path = SignalPath(
        source: flac,
        processing: const SignalProcessing(),
        output: const SignalOutput(backend: HifiBackend.mpv, exclusive: true, resampled: true),
        bitPerfectMode: true,
      );
      expect(path.verdict, SignalPathVerdict.notBitPerfect);
      expect(path.issues, contains(SignalPathIssue.resampled));
    });

    test("an unknown output rate is not claimed bit-perfect", () {
      final path = SignalPath(
        source: flac,
        processing: const SignalProcessing(),
        output: const SignalOutput(backend: HifiBackend.mpv, exclusive: true),
        bitPerfectMode: true,
      );
      expect(path.verdict, SignalPathVerdict.unknown);
    });

    test("an ALSA hw: device needs no exclusive flag, a shared one does", () {
      SignalPath on(String device) => SignalPath(
        source: flac,
        processing: const SignalProcessing(),
        output: SignalOutput(backend: HifiBackend.mpv, device: device, exclusive: false, resampled: false),
        bitPerfectMode: true,
      );
      expect(on("alsa/hw:1,0").verdict, SignalPathVerdict.bitPerfect);
      expect(on("pipewire").issues, contains(SignalPathIssue.sharedMixer));
    });

    test("macOS at best is transparent, not bit-perfect", () {
      final path = SignalPath(
        source: flac,
        processing: const SignalProcessing(),
        output: const SignalOutput(backend: HifiBackend.coreAudio, exclusive: true, resampled: false),
        bitPerfectMode: true,
      );
      expect(path.verdict, SignalPathVerdict.transparent);
    });

    test("Android: a 24-bit source through the 16-bit decoder is not bit-perfect", () {
      final path = SignalPath(
        source: flac,
        processing: const SignalProcessing(),
        output: const SignalOutput(
          backend: HifiBackend.androidMixer,
          bitPerfectMixer: true,
          decoderBits: 16,
          resampled: false,
        ),
        bitPerfectMode: true,
      );
      expect(path.issues, [SignalPathIssue.decoderDepth]);
    });

    test("iOS is never bit-perfect; processing stages are listed", () {
      final path = SignalPath(
        source: flac,
        processing: const SignalProcessing(volume: 0.5, replayGain: true, speed: 1.25),
        output: const SignalOutput(backend: HifiBackend.none),
        bitPerfectMode: false,
      );
      expect(path.verdict, SignalPathVerdict.notBitPerfect);
      expect(
        path.issues,
        containsAll([
          SignalPathIssue.platform,
          SignalPathIssue.volume,
          SignalPathIssue.replayGain,
          SignalPathIssue.speed,
        ]),
      );
      expect(path.issues, isNot(contains(SignalPathIssue.modeOff)));
    });

    test("DSD converted to PCM is named as such; DoP is not a conversion", () {
      const dsd = DsdTrackInfo(
        container: "dsf",
        dsdRate: 2822400,
        channels: 2,
        dst: false,
        delivery: DsdDelivery.pcm,
        outputRate: 88200,
      );
      const dop = DsdTrackInfo(
        container: "dsf",
        dsdRate: 2822400,
        channels: 2,
        dst: false,
        delivery: DsdDelivery.dop,
        outputRate: 176400,
      );
      const output = SignalOutput(backend: HifiBackend.mpv, exclusive: true, resampled: false);
      expect(
        SignalPath(
          source: const SignalSource(dsd: dsd),
          processing: const SignalProcessing(),
          output: output,
          bitPerfectMode: true,
        ).issues,
        [SignalPathIssue.dsdConverted],
      );
      expect(
        SignalPath(
          source: const SignalSource(dsd: dop),
          processing: const SignalProcessing(),
          output: output,
          bitPerfectMode: true,
        ).verdict,
        SignalPathVerdict.bitPerfect,
      );
    });
  });
}
