# Hi-Fi output: bit-perfect, DSD, SACD

Settings → Playback → **Hi-Fi output**. Off by default. Code in `lib/services/hifi/`.

## Bit-perfect mode

When on, every stage of the app that changes samples is bypassed, on every platform:

| Stage | In bit-perfect mode |
|---|---|
| Volume (app slider, fades, ducking) | Held at 100% (`PlayerVolumeController`). Use the DAC/amp volume. |
| ReplayGain / normalization | Off (volume gain and Android `LoudnessEnhancer`). |
| Equalizer (Android, Darwin) | Off, whatever its setting. |
| Crossfade / Automix | Off: tracks change gaplessly. |
| Playback speed | Forced to 1×. |

Then each platform does what it can with the output:

| Platform | Output | What bit-perfect means there | Verdict at best |
|---|---|---|---|
| Linux | libmpv (`just_audio_media_kit`) | `af` cleared, `volume=100`, `replaygain=no`, no forced rate/format/channels, `audio-pitch-correction=no` and media_kit pitch control off (so no `scaletempo`), `audio-exclusive=yes` (option), output device picker (pick an ALSA `hw:` device to skip PulseAudio/PipeWire). mpv opens the device at the track's rate; if the device refuses it, mpv resamples and the panel says so. | Bit-perfect |
| Windows | libmpv, WASAPI | Same properties; `audio-exclusive=yes` is WASAPI exclusive mode. | Bit-perfect |
| macOS | AVFoundation on CoreAudio | The default output device's nominal rate is set to each track's rate (when the device lists it), so AVPlayer's converter runs 1:1; hog mode (option) keeps other processes off the device; the previous rate is restored when the mode is turned off. Samples still go through the HAL's float mixer at unity gain: transparent for 16/24-bit, but not proven bit-exact. A native CoreAudio/AUHAL player would be needed for a guarantee. | "No resampling, unity gain" (never claimed bit-perfect) |
| Android 14+ | ExoPlayer → AudioTrack | With a USB DAC, `AudioManager.setPreferredMixerAttributes` with a `MIXER_BEHAVIOR_BIT_PERFECT` mixer at the track's rate, `PCM_16BIT`, for `USAGE_MEDIA`. ExoPlayer decodes to 16-bit (its default), so 24-bit sources are reduced before the mixer and are reported as not bit-perfect. No USB DAC, older Android, or no matching mixer: shared output, reported. | Bit-perfect for 16-bit sources |
| Android < 14 | ExoPlayer | Shared mixer; the bypasses above still apply. | Not bit-perfect |
| iOS, iPadOS, tvOS | AVAudioSession | Not possible: the system mixes and picks the rate. The switch is disabled with an explanation. | Not bit-perfect |

On Linux/Windows, media_kit's pitch control (which routes speed through a `scaletempo` filter) is switched off when bit-perfect is on at launch; turning bit-perfect on while the app runs clears `af` again at every track change, but a restart gives the clean path from the first track. Turning it off gives the device back (`audio-exclusive=no`, `audio-device=auto`).

Native code: `macos/Runner/MainFlutterWindow.swift` (`HifiChannel`), `android/app/src/main/kotlin/fr/nytuo/diapason/HifiChannel.kt`, both on the `fr.nytuo.diapason/hifi` method channel (`lib/services/hifi/native_output.dart`). mpv is reached through the `onPlayerReady`/`players` hook of the vendored `packages/just_audio_media_kit`.

## Signal path panel

Tap the format line (feature chips) under the track in the player. It shows, refreshed every 2 s:

- **Source**: codec, rate, depth, channels from the server's metadata; for DSD the DSD rate (DSD64…DSD1024), channels and DST.
- **Decoding**: by the player, transcoded by the server, or the DSD path (DoP / converted to PCM here / decoded by ffmpeg).
- **Processing**: the stages above that are active, or "Volume held at 100%".
- **Output**: what the output reports — mpv `current-ao`, `audio-device`, `audio-out-params` (rate, format), `audio-exclusive`, and `af`; macOS the device name, nominal rate, physical bit depth and hog state; Android the mixer the framework accepted.
- **Verdict**: *Bit-perfect* only when nothing is in the way **and** the output reported its rate equal to the source's. If the output did not report, the verdict is *Not verified*, never *Bit-perfect*. macOS tops out at *No resampling, unity gain*.

The rules live in `SignalPath` (`lib/services/hifi/signal_path.dart`, unit-tested).

## DSD

| | Linux / Windows (mpv) | macOS | Android | iOS |
|---|---|---|---|---|
| DSF / DFF, bit-perfect on, mode "DoP" | **DoP** (24-bit PCM at DSD/16 with 0x05/0xFA markers), stereo | PCM 88.2 kHz/24 | PCM 88.2 kHz/24 | PCM 88.2 kHz/24 |
| DSF / DFF otherwise | mpv/ffmpeg decodes to PCM (352.8 kHz float) | PCM 88.2 kHz/24 | PCM 88.2 kHz/24 | PCM 88.2 kHz/24 |
| DFF with DST | ffmpeg's DST decoder (if the libmpv build has it; else mpv's error is reported) | Not supported, reported | Not supported, reported | Not supported, reported |
| SACD ISO, uncompressed | DoP or PCM as above | PCM | PCM | PCM |
| SACD ISO, DST | Re-wrapped as DSDIFF-DST and decoded by ffmpeg | Not supported, reported | Not supported, reported | Not supported, reported |
| Native DSD (ASIO / ALSA `DSD_U32`) | Not done: mpv has no native DSD output | — | — | — |

- DoP is only used where the output is bit-perfect, because any change to a DoP sample turns it into loud noise. It needs a DoP-capable DAC and a device that accepts 176.4 kHz (DSD64), 352.8 kHz (DSD128)… Multichannel DSD is converted to PCM (DoP is stereo here).
- DSD→PCM conversion (`dsd_to_pcm.dart`): `dsd2pcm` FIR (8:1, port of Chilpa's port of Sebastian Gesemann's code) then half-band stages to 88.2 kHz, −6 dB headroom, 24-bit. Multichannel is folded to stereo. It runs on the isolate that hosts the player, yielding between blocks.
- Delivery to the player: `DsdAudioSource` (a just_audio `StreamAudioSource` behind just_audio's local proxy) builds a virtual WAV (or DSDIFF-DST) and serves any byte range on demand, so seeking works.
- Sources: local files (Local folder backend scans `.dsf`, `.dff`, `.iso`), downloaded files, and raw server streams (not transcoded). A remote DSF/DFF is downloaded progressively to a temporary file and played as bytes arrive. SACD images are read from local files only.

### SACD images

`lib/services/hifi/dsd/sacd.dart`, a port of Chilpa's `chilpa-sacd`: 2048-byte (or 2064-byte raw) sectors, Master TOC (`SACDMTOC` at 510/520/530, album text in `SACDText`), stereo area TOC (`TWOCHTOC`, `SACDTRL1`/`SACDTRL2` track lists, `SACDTTxt` titles in Latin character sets), audio sectors with 11-bit packet lengths checked to add up to 2048. Uncompressed frames are 9408 bytes, channels interleaved byte by byte; the first frame of a track is found by its frame-start flag, seeks by binary search on timecodes. The multichannel area is ignored. Each track of the stereo area is listed as a track of an album named after the disc.

## Tests

`test/hifi_dsd_test.dart` builds synthetic DSF, DFF (incl. DST header) and SACD ISO images (uncompressed and DST) byte by byte and checks parsing, channel order, seeking, DoP packing and markers, the virtual WAV ranges, and the DSDIFF-DST re-wrap. `test/hifi_signal_path_test.dart` covers the delivery choice, the mpv properties and the verdict rules.

## Not verified on hardware

Built for macOS (debug); the Android Kotlin channel was not compiled here (the local SDK lacks an accepted NDK licence). Nothing was tried on a DAC: mpv exclusive/hw output and DoP lock on a DAC, CoreAudio hog mode with AVPlayer, the Android 14 bit-perfect mixer. Check the signal path panel and the DAC's display first.
