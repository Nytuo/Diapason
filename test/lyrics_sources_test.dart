import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:diapason/services/lyrics/lyrics_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the sync badge tells plain, line-synced and word-synced lyrics apart", () {
    expect(LyricsSync.of(LrcParser.plain("One\nTwo")), LyricsSync.plain);
    expect(LyricsSync.of(LrcParser.parse("[00:01.00]One")), LyricsSync.line);
    expect(LyricsSync.of(LrcParser.parse("[00:01.00]<00:01.00>One <00:01.50>two")), LyricsSync.word);
    expect(LyricsSync.of(null), LyricsSync.plain);
  });

  test("options are labelled by their source", () {
    final lyrics = LyricDto(lyrics: [LyricLine(text: "x")]);
    expect(LyricsOption(origin: LyricsOrigin.amll, lyrics: lyrics).label, "AMLL TTML DB");
    expect(LyricsOption(origin: LyricsOrigin.server, lyrics: lyrics, label: "Home Jellyfin").label, "Home Jellyfin");
    expect(LyricsOrigin.lrclib.isOnlineDatabase, isTrue);
    expect(LyricsOrigin.file.isOnlineDatabase, isFalse);
  });
}
