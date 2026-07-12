import 'dart:typed_data';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Saved queues store their track ids as packed bytes.
///
/// Upstream packed each id as 16 raw bytes, which only holds if every id is a
/// 32-character hex GUID — true for Jellyfin, false for every other source
/// Diapason talks to. Playing a Navidrome or YouTube track threw
/// `FormatException: Invalid radix-16 number` on the next queue save, which runs
/// on a timer, so it fired every few seconds for as long as the track played.
void main() {
  /// Builds the info the way the queue does, so the getters can read it back.
  FinampStorableQueueInfo infoWith({
    List<String> previous = const [],
    String? current,
    List<String> nextUp = const [],
    List<String> queue = const [],
  }) => FinampStorableQueueInfo(
    packedPreviousTracks: FinampStorableQueueInfo.packIds(previous.map(BaseItemId.new).toList()),
    packedCurrentTrack: current == null
        ? Uint8List(0)
        : FinampStorableQueueInfo.packIds([BaseItemId(current)]),
    packedNextUp: FinampStorableQueueInfo.packIds(nextUp.map(BaseItemId.new).toList()),
    packedQueue: FinampStorableQueueInfo.packIds(queue.map(BaseItemId.new).toList()),
    currentTrackSeek: null,
    creation: 0,
    sourceList: const [],
    sourceIndex: 0,
    trackSourceIndexes: Uint8List(0),
    packedShuffleOrder: null,
  );

  test("round-trips source-scoped ids, whatever their shape", () {
    // A Subsonic id, a YouTube id, a local file's hash, a raw Jellyfin GUID.
    final info = infoWith(
      previous: ["sub-d8240~aelw4dXEy3SuL2Szt3PAgX", "yt~6pL9A-KjUn0"],
      current: "local~3f2b1c8e9d",
      nextUp: ["plex-1~/library/metadata/4821"],
      queue: ["3f9e8a2b4c1d5e6f7a8b9c0d1e2f3a4b"],
    );

    expect(info.previousTracks.map((id) => id.raw), [
      "sub-d8240~aelw4dXEy3SuL2Szt3PAgX",
      "yt~6pL9A-KjUn0",
    ]);
    expect(info.currentTrack!.raw, "local~3f2b1c8e9d");
    expect(info.nextUp.single.raw, "plex-1~/library/metadata/4821");
    expect(info.queue.single.raw, "3f9e8a2b4c1d5e6f7a8b9c0d1e2f3a4b");
  });

  test("counts tracks across all four lists", () {
    final info = infoWith(
      previous: ["sub-1~a", "sub-1~b"],
      current: "yt~c",
      nextUp: ["sub-1~d"],
      queue: ["sub-1~e", "sub-1~f", "sub-1~g"],
    );

    expect(info.trackCount, 7);
  });

  test("an empty queue packs and unpacks to nothing", () {
    final info = infoWith();

    expect(info.trackCount, 0);
    expect(info.queue, isEmpty);
    expect(info.currentTrack, isNull);
  });

  test("ids survive non-ascii, which utf-8 encodes as more bytes than characters", () {
    // A length prefix counting characters rather than bytes would truncate here.
    final info = infoWith(current: "local~Björk – Jóga");

    expect(info.currentTrack!.raw, "local~Björk – Jóga");
  });

  test("reads a queue saved by an older build, which packed raw 16-byte GUIDs", () {
    // Written the way upstream wrote it: the hex GUID, decoded to bytes.
    const guid = "3f9e8a2b4c1d5e6f7a8b9c0d1e2f3a4b";
    final legacy = Uint8List.fromList([
      for (int i = 0; i < 32; i += 2) int.parse(guid.substring(i, i + 2), radix: 16),
    ]);

    final info = FinampStorableQueueInfo(
      packedPreviousTracks: Uint8List(0),
      packedCurrentTrack: legacy,
      packedNextUp: Uint8List(0),
      packedQueue: Uint8List(0),
      currentTrackSeek: null,
      creation: 0,
      sourceList: const [],
      sourceIndex: 0,
      trackSourceIndexes: Uint8List(0),
      packedShuffleOrder: null,
    );

    expect(info.currentTrack!.raw, guid);
    expect(info.trackCount, 1);
  });

  test("refuses an id too long to store, rather than silently truncating it", () {
    // Truncation would corrupt the queue in a way that only surfaces on restore.
    expect(
      () => FinampStorableQueueInfo.packIds([BaseItemId("x" * 70000)]),
      throwsArgumentError,
    );
  });
}
