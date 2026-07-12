import 'package:diapason/services/backends/item_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The player's info chips (codec, bitrate, size, sample rate) all read
/// `mediaSources`, which only Jellyfin sends. Subsonic sends the same facts under
/// different names — so a track mapped without them looked to the UI like a track
/// nobody knew anything about: "codec: Unknown, size: null".
void main() {
  final map = ItemMapper("sub-1");

  test("a track carries the file's details, so the player can show them", () {
    final track = map.track(
      nativeId: "t1",
      name: "Rivalry",
      duration: const Duration(minutes: 3, seconds: 20),
      container: "flac",
      codec: "flac",
      size: 24000000,
      bitrateKbps: 960,
      sampleRate: 44100,
      bitDepth: 16,
      channels: 2,
    );

    final source = track.mediaSources!.single;
    expect(source.container, "flac");
    expect(source.size, 24000000);
    // Subsonic reports kbps; everything downstream speaks bits per second.
    expect(source.bitrate, 960000);

    final audio = source.mediaStreams.single;
    expect(audio.type, "Audio");
    expect(audio.codec, "flac");
    expect(audio.bitRate, 960000);
    expect(audio.sampleRate, 44100);
    expect(audio.bitDepth, 16);
    expect(audio.channels, 2);
  });

  test("a track the source said nothing about claims nothing", () {
    // An empty media source would be a claim of its own — "we know this file, and
    // it has no codec" — so there is none.
    final track = map.track(nativeId: "t2", name: "Unknown");

    expect(track.mediaSources, isNull);
  });

  test("older servers send only what they have, and that is still worth showing", () {
    // samplingRate/bitDepth/channelCount are OpenSubsonic additions.
    final track = map.track(nativeId: "t3", name: "Old", container: "mp3", bitrateKbps: 320);

    final source = track.mediaSources!.single;
    expect(source.bitrate, 320000);
    expect(source.mediaStreams.single.sampleRate, isNull);
    // With no codec given, the container is the best answer available.
    expect(source.mediaStreams.single.codec, "mp3");
  });
}
