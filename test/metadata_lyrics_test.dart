import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:diapason/services/metadata_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// The player offers the lyrics view only when the metadata says there are lyrics
/// to show. That used to mean "Jellyfin sent a Lyric media stream" — so lyrics
/// fetched from LRCLIB for a Subsonic track were found, logged, and then never
/// displayed.
void main() {
  final map = ItemMapper("sub-1");

  MetadataProvider metadata({LyricDto? lyrics, bool jellyfinLyricStream = false}) {
    final item = map.track(nativeId: "t1", name: "Rivalry", container: "flac");
    return MetadataProvider(
      item: item,
      playbackInfo: PlaybackInfoResponse(
        mediaSources: [
          MediaSourceInfo(
            id: item.id,
            protocol: "Http",
            type: "Default",
            isRemote: true,
            supportsTranscoding: false,
            supportsDirectStream: true,
            supportsDirectPlay: true,
            isInfiniteStream: false,
            requiresOpening: false,
            requiresClosing: false,
            requiresLooping: false,
            supportsProbing: false,
            readAtNativeFramerate: false,
            ignoreDts: false,
            ignoreIndex: false,
            genPtsInput: false,
            mediaStreams: [
              if (jellyfinLyricStream)
                MediaStream(
                  type: "Lyric",
                  index: 0,
                  isDefault: true,
                  isInterlaced: false,
                  isForced: false,
                  isExternal: false,
                  isTextSubtitleStream: false,
                  supportsExternalStream: false,
                ),
            ],
          ),
        ],
      ),
      lyrics: lyrics,
    );
  }

  test("lyrics we are holding count as lyrics, whoever found them", () {
    // A Subsonic track has no Jellyfin Lyric stream and never will.
    final withLrclib = metadata(lyrics: LrcParser.parse("[00:01.00]Line"));

    expect(withLrclib.hasLyrics, isTrue);
  });

  test("Jellyfin announcing lyrics still counts, before they have been fetched", () {
    expect(metadata(jellyfinLyricStream: true).hasLyrics, isTrue);
  });

  test("no lyrics, and nobody claiming any, means none", () {
    expect(metadata().hasLyrics, isFalse);
  });
}
