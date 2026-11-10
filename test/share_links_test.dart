import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/share_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BaseItemDto item(String id, {String? name, String? type, String? albumArtist}) =>
      BaseItemDto(id: BaseItemId(id), name: name, type: type, albumArtist: albumArtist);

  test('a link names the item so another device can find it', () {
    final link = ShareLinks.linkFor(item("jf-1a2b3~abc", name: "Discovery", type: "MusicAlbum", albumArtist: "Daft Punk"));
    expect(link.scheme, "diapason");
    expect(link.host, "show");
    expect(link.pathSegments, ["jf-1a2b3~abc"]);
    expect(link.queryParameters, {"t": "MusicAlbum", "n": "Discovery", "a": "Daft Punk"});
  });

  test('names with spaces and symbols survive the round trip', () {
    final link = ShareLinks.linkFor(item("x~1", name: "Rock & Roll / Part 2?", type: "Audio"));
    expect(Uri.parse(link.toString()).queryParameters["n"], "Rock & Roll / Part 2?");
  });

  test('an artist link carries no artist of its own', () {
    final link = ShareLinks.linkFor(item("x~2", name: "Daft Punk", type: "MusicArtist", albumArtist: "Daft Punk"));
    expect(link.queryParameters.containsKey("a"), isFalse);
  });

  test('the share text reads well before the link', () {
    final text = ShareLinks.shareText(item("x~3", name: "One More Time", type: "Audio", albumArtist: "Daft Punk"));
    expect(text.split("\n").first, "One More Time — Daft Punk on Diapason");
    expect(text.split("\n").last, startsWith("diapason://show/"));
  });
}
