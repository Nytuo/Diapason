import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/uploader/youtube_library_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final yt = ItemMapper("yt");
  final jf = ItemMapper("jf-1");

  test("YouTube titles are cleaned down to the song", () {
    expect(YouTubeLibraryImport.cleanTitle("Coldplay - Yellow (Official Video)", artist: "Coldplay"), "Yellow");
    expect(YouTubeLibraryImport.cleanTitle("Yellow [Lyrics]", artist: "Coldplay - Topic"), "Yellow");
    // A dash that isn't "Artist - " stays.
    expect(YouTubeLibraryImport.cleanTitle("Song - Live at Wembley", artist: "Queen"), "Song - Live at Wembley");
  });

  test("the library copy is found by its words, never another YouTube item", () async {
    final youtube = yt.track(nativeId: "abc", name: "Coldplay - Yellow (Official Video)", artist: "Coldplay");
    final found = await YouTubeLibraryImport.findInLibrary(
      youtube,
      (search) async => [
        yt.track(nativeId: "abc", name: "Yellow", artist: "Coldplay"),
        jf.track(nativeId: "1", name: "Yellow Submarine", artist: "The Beatles"),
        jf.track(nativeId: "2", name: "Yellow", artist: "Coldplay"),
      ],
    );
    expect(found?.id, const BaseItemId("jf-1~2"));
  });

  test("nothing close enough is not a match", () async {
    final youtube = yt.track(nativeId: "abc", name: "Fix You", artist: "Coldplay");
    final found = await YouTubeLibraryImport.findInLibrary(
      youtube,
      (search) async => [jf.track(nativeId: "1", name: "Paradise", artist: "Coldplay")],
    );
    expect(found, isNull);
  });

  test("only YouTube items count as YouTube", () {
    expect(YouTubeLibraryImport.isYouTube(yt.track(nativeId: "a", name: "x")), isTrue);
    expect(YouTubeLibraryImport.isYouTube(jf.track(nativeId: "a", name: "x")), isFalse);
  });
}
