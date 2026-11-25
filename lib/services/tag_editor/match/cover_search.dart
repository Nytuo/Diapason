import 'package:diapason/services/tag_editor/match/lookup_http.dart';
import 'package:logging/logging.dart';

enum CoverSource {
  coverArtArchive("Cover Art Archive"),
  itunes("iTunes"),
  deezer("Deezer");

  const CoverSource(this.label);
  final String label;
}

class CoverCandidate {
  const CoverCandidate({
    required this.source,
    required this.imageUrl,
    required this.thumbnailUrl,
    this.title,
    this.artist,
    this.nominalSize,
  });

  final CoverSource source;

  /// Largest image the source offers.
  final Uri imageUrl;
  final Uri thumbnailUrl;
  final String? title;
  final String? artist;

  /// Edge length the source advertises (actual size is read once downloaded);
  /// null when the source doesn't say.
  final int? nominalSize;
}

/// Keyless cover lookups: Cover Art Archive (by MusicBrainz release), iTunes
/// Search API and Deezer's public API. Only album/artist names are sent.
class CoverSearch {
  CoverSearch(this._http);

  final LookupHttp _http;
  static final _log = Logger("CoverSearch");

  /// Runs every applicable source; a failing source is logged and skipped.
  Future<List<CoverCandidate>> search({
    String? album,
    String? artist,
    String? releaseId,
    String? releaseGroupId,
  }) async {
    final futures = <Future<List<CoverCandidate>>>[
      if (releaseId != null) _safe(CoverSource.coverArtArchive, () => coverArtArchive(releaseId: releaseId)),
      if (releaseId == null && releaseGroupId != null)
        _safe(CoverSource.coverArtArchive, () => coverArtArchive(releaseGroupId: releaseGroupId)),
      if (album != null && album.trim().isNotEmpty) ...[
        _safe(CoverSource.itunes, () => itunes(album, artist)),
        _safe(CoverSource.deezer, () => deezer(album, artist)),
      ],
    ];
    return (await Future.wait(futures)).expand((l) => l).toList();
  }

  Future<List<CoverCandidate>> _safe(CoverSource source, Future<List<CoverCandidate>> Function() run) async {
    try {
      return await run();
    } catch (e) {
      _log.warning("${source.label} cover search failed: $e");
      return const [];
    }
  }

  Future<List<CoverCandidate>> coverArtArchive({String? releaseId, String? releaseGroupId}) async {
    final path = releaseId != null ? "release/$releaseId" : "release-group/$releaseGroupId";
    return parseCoverArtArchive(await _http.getJson(Uri.parse("https://coverartarchive.org/$path")));
  }

  static List<CoverCandidate> parseCoverArtArchive(dynamic json) {
    final images = ((json as Map?)?["images"] as List? ?? const []).cast<Map<String, dynamic>>();
    final sorted = [...images]..sort((a, b) => (b["front"] == true ? 1 : 0) - (a["front"] == true ? 1 : 0));
    return [
      for (final image in sorted)
        if (image["image"] is String)
          CoverCandidate(
            source: CoverSource.coverArtArchive,
            imageUrl: Uri.parse(_https(image["image"] as String)),
            thumbnailUrl: Uri.parse(
              _https(
                ((image["thumbnails"] as Map?)?["500"] ??
                        (image["thumbnails"] as Map?)?["large"] ??
                        (image["thumbnails"] as Map?)?["250"] ??
                        image["image"])
                    as String,
              ),
            ),
            title: ((image["types"] as List?)?.join(", ")),
          ),
    ];
  }

  static String _https(String url) => url.replaceFirst("http://", "https://");

  Future<List<CoverCandidate>> itunes(String album, String? artist) async {
    final term = [artist, album].nonNulls.where((s) => s.trim().isNotEmpty).join(" ");
    return parseItunes(
      await _http.getJson(
        Uri.https("itunes.apple.com", "/search", {"term": term, "entity": "album", "media": "music", "limit": "10"}),
      ),
    );
  }

  static List<CoverCandidate> parseItunes(dynamic json) => [
    for (final r in ((json as Map?)?["results"] as List? ?? const []).cast<Map<String, dynamic>>())
      if (r["artworkUrl100"] is String)
        CoverCandidate(
          source: CoverSource.itunes,
          // The artwork URL accepts any size; 3000px is the largest it serves.
          imageUrl: Uri.parse((r["artworkUrl100"] as String).replaceFirst(RegExp(r"/\d+x\d+bb\."), "/3000x3000bb.")),
          thumbnailUrl: Uri.parse((r["artworkUrl100"] as String).replaceFirst(RegExp(r"/\d+x\d+bb\."), "/300x300bb.")),
          title: r["collectionName"] as String?,
          artist: r["artistName"] as String?,
          nominalSize: 3000,
        ),
  ];

  Future<List<CoverCandidate>> deezer(String album, String? artist) async {
    final q = artist == null || artist.trim().isEmpty ? album : 'artist:"$artist" album:"$album"';
    return parseDeezer(await _http.getJson(Uri.https("api.deezer.com", "/search/album", {"q": q, "limit": "10"})));
  }

  static List<CoverCandidate> parseDeezer(dynamic json) => [
    for (final r in ((json as Map?)?["data"] as List? ?? const []).cast<Map<String, dynamic>>())
      if (r["cover_xl"] is String)
        CoverCandidate(
          source: CoverSource.deezer,
          imageUrl: Uri.parse(r["cover_xl"] as String),
          thumbnailUrl: Uri.parse((r["cover_big"] ?? r["cover_xl"]) as String),
          title: r["title"] as String?,
          artist: (r["artist"] as Map?)?["name"] as String?,
          nominalSize: 1000,
        ),
  ];
}
