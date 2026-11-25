import 'package:collection/collection.dart';
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/match/lookup_http.dart';
import 'package:diapason/services/tag_editor/match/match_scoring.dart';

/// What the editor knows about a track before matching.
class MatchQuery {
  const MatchQuery({this.title, this.artists = const [], this.album, this.albumArtists = const [], this.duration});

  factory MatchQuery.fromTags(AudioTags tags, {Duration? duration}) => MatchQuery(
    title: tags[TagField.title],
    artists: tags.all(TagField.artists),
    album: tags[TagField.album],
    albumArtists: tags.all(TagField.albumArtists),
    duration: duration,
  );

  final String? title;
  final List<String> artists;
  final String? album;
  final List<String> albumArtists;
  final Duration? duration;
}

class MbArtistCredit {
  const MbArtistCredit(this.name, this.id, this.joinPhrase);

  final String name;
  final String? id;
  final String joinPhrase;

  static List<MbArtistCredit> parse(dynamic json) => [
    for (final c in (json as List? ?? const []).cast<Map<String, dynamic>>())
      MbArtistCredit(
        (c["name"] ?? (c["artist"] as Map?)?["name"] ?? "") as String,
        (c["artist"] as Map?)?["id"] as String?,
        (c["joinphrase"] ?? "") as String,
      ),
  ];

  static String display(List<MbArtistCredit> credits) => credits.map((c) => "${c.name}${c.joinPhrase}").join();
}

/// A release a recording appears on, as returned inside a recording search.
class MbReleaseRef {
  const MbReleaseRef({
    required this.id,
    required this.title,
    this.date,
    this.country,
    this.status,
    this.releaseGroupId,
    this.primaryType,
    this.trackCount,
    this.trackNumber,
    this.discNumber,
  });

  final String id;
  final String title;
  final String? date;
  final String? country;
  final String? status;
  final String? releaseGroupId;
  final String? primaryType;
  final int? trackCount;
  final String? trackNumber;
  final int? discNumber;

  static MbReleaseRef parse(Map<String, dynamic> json) {
    final medium = (json["media"] as List? ?? const []).cast<Map<String, dynamic>>().firstOrNull;
    final track = (medium?["track"] as List? ?? medium?["tracks"] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .firstOrNull;
    final group = json["release-group"] as Map<String, dynamic>?;
    return MbReleaseRef(
      id: json["id"] as String,
      title: (json["title"] ?? "") as String,
      date: json["date"] as String?,
      country: json["country"] as String?,
      status: json["status"] as String?,
      releaseGroupId: group?["id"] as String?,
      primaryType: group?["primary-type"] as String?,
      trackCount: (medium?["track-count"] ?? json["track-count"]) as int?,
      trackNumber: track?["number"]?.toString(),
      discNumber: medium?["position"] as int?,
    );
  }
}

class MbRecordingCandidate {
  MbRecordingCandidate({
    required this.id,
    required this.title,
    required this.artists,
    required this.length,
    required this.releases,
    required this.searchScore,
  });

  final String id;
  final String title;
  final List<MbArtistCredit> artists;
  final Duration? length;
  final List<MbReleaseRef> releases;

  /// MusicBrainz's own 0–100 search relevance.
  final int searchScore;

  /// Our 0..1 confidence against the query, and the release we'd pick.
  double confidence = 0;
  MbReleaseRef? bestRelease;

  static MbRecordingCandidate parse(Map<String, dynamic> json) => MbRecordingCandidate(
    id: json["id"] as String,
    title: (json["title"] ?? "") as String,
    artists: MbArtistCredit.parse(json["artist-credit"]),
    length: json["length"] == null ? null : Duration(milliseconds: json["length"] as int),
    releases: [
      for (final r in (json["releases"] as List? ?? const []).cast<Map<String, dynamic>>()) MbReleaseRef.parse(r),
    ],
    searchScore: (json["score"] ?? 0) as int,
  );

  void score(MatchQuery q) {
    double releaseScore(MbReleaseRef r) =>
        (q.album == null ? 0.5 : MatchScoring.similarity(q.album, r.title)) +
        (r.status == "Official" ? 0.1 : 0) +
        (r.primaryType == "Album" ? 0.05 : 0);
    bestRelease = releases.isEmpty ? null : releases.reduce((a, b) => releaseScore(b) > releaseScore(a) ? b : a);
    confidence = MatchScoring.weighted([
      (q.title == null ? null : MatchScoring.similarity(q.title, title), 0.4),
      (MatchScoring.artistsSimilarity(q.artists, artists.map((a) => a.name).toList()), 0.25),
      (MatchScoring.durationScore(q.duration, length), 0.25),
      (q.album == null || bestRelease == null ? null : MatchScoring.similarity(q.album, bestRelease!.title), 0.1),
    ]);
  }
}

class MbReleaseCandidate {
  MbReleaseCandidate({
    required this.id,
    required this.title,
    required this.artists,
    this.date,
    this.country,
    this.trackCount,
    this.format,
    this.releaseGroupId,
    this.searchScore = 0,
  });

  final String id;
  final String title;
  final List<MbArtistCredit> artists;
  final String? date;
  final String? country;
  final int? trackCount;
  final String? format;
  final String? releaseGroupId;
  final int searchScore;
  double confidence = 0;

  static MbReleaseCandidate parse(Map<String, dynamic> json) {
    final media = (json["media"] as List? ?? const []).cast<Map<String, dynamic>>();
    return MbReleaseCandidate(
      id: json["id"] as String,
      title: (json["title"] ?? "") as String,
      artists: MbArtistCredit.parse(json["artist-credit"]),
      date: json["date"] as String?,
      country: json["country"] as String?,
      trackCount: json["track-count"] as int?,
      format: media.map((m) => m["format"]).nonNulls.toSet().join(" + "),
      releaseGroupId: (json["release-group"] as Map?)?["id"] as String?,
      searchScore: (json["score"] ?? 0) as int,
    );
  }

  void score(MatchQuery q, {int? trackCount, int? year}) {
    final releaseYear = int.tryParse((date ?? "").split("-").first);
    confidence = MatchScoring.weighted([
      (q.album == null ? null : MatchScoring.similarity(q.album, title), 0.45),
      (
        MatchScoring.artistsSimilarity(
          q.albumArtists.isNotEmpty ? q.albumArtists : q.artists,
          artists.map((a) => a.name).toList(),
        ),
        0.25,
      ),
      (trackCount == null ? null : MatchScoring.countScore(trackCount, this.trackCount), 0.2),
      (year == null || releaseYear == null ? null : (year == releaseYear ? 1.0 : 0.3), 0.1),
    ]);
  }
}

class MbTrack {
  const MbTrack({
    required this.id,
    required this.recordingId,
    required this.title,
    required this.artists,
    required this.position,
    required this.number,
    required this.discNumber,
    this.length,
  });

  final String id;
  final String recordingId;
  final String title;
  final List<MbArtistCredit> artists;
  final int position;
  final String number;
  final int discNumber;
  final Duration? length;
}

/// A full release lookup (tracks included).
class MbRelease {
  const MbRelease({
    required this.id,
    required this.title,
    required this.artists,
    required this.tracks,
    required this.discCount,
    this.date,
    this.releaseGroupId,
    this.genres = const [],
  });

  final String id;
  final String title;
  final List<MbArtistCredit> artists;
  final List<MbTrack> tracks;
  final int discCount;
  final String? date;
  final String? releaseGroupId;
  final List<String> genres;

  int tracksOnDisc(int disc) => tracks.where((t) => t.discNumber == disc).length;

  static MbRelease parse(Map<String, dynamic> json) {
    final media = (json["media"] as List? ?? const []).cast<Map<String, dynamic>>();
    final tracks = <MbTrack>[];
    for (final medium in media) {
      final disc = (medium["position"] ?? 1) as int;
      for (final t in (medium["tracks"] as List? ?? const []).cast<Map<String, dynamic>>()) {
        final recording = t["recording"] as Map<String, dynamic>? ?? const {};
        final length = t["length"] ?? recording["length"];
        tracks.add(
          MbTrack(
            id: t["id"] as String,
            recordingId: (recording["id"] ?? "") as String,
            title: (t["title"] ?? recording["title"] ?? "") as String,
            artists: MbArtistCredit.parse(t["artist-credit"] ?? recording["artist-credit"]),
            position: (t["position"] ?? 0) as int,
            number: (t["number"] ?? "${t["position"]}").toString(),
            discNumber: disc,
            length: length == null ? null : Duration(milliseconds: length as int),
          ),
        );
      }
    }
    final group = json["release-group"] as Map<String, dynamic>?;
    final genres = [
      for (final g in ((json["genres"] ?? group?["genres"]) as List? ?? const []).cast<Map<String, dynamic>>())
        (count: (g["count"] ?? 0) as int, name: g["name"] as String),
    ]..sort((a, b) => b.count.compareTo(a.count));
    return MbRelease(
      id: json["id"] as String,
      title: (json["title"] ?? "") as String,
      artists: MbArtistCredit.parse(json["artist-credit"]),
      tracks: tracks,
      discCount: media.isEmpty ? 1 : media.length,
      date: json["date"] as String?,
      releaseGroupId: group?["id"] as String?,
      genres: genres.take(3).map((g) => g.name).toList(),
    );
  }

  /// Album-level fields every track of the release shares.
  void applyAlbumFields(AudioTags tags, {bool includeGenres = false}) {
    tags.setOne(TagField.album, title);
    tags.set(TagField.albumArtists, artists.map((a) => a.name).toList());
    tags.set(TagField.musicBrainzAlbumArtistIds, artists.map((a) => a.id).nonNulls.toList());
    tags.setOne(TagField.musicBrainzReleaseId, id);
    tags.setOne(TagField.musicBrainzReleaseGroupId, releaseGroupId);
    if (date != null && date!.isNotEmpty) tags.setOne(TagField.date, date);
    tags.setNumber(TagField.discTotal, discCount);
    if (includeGenres && genres.isNotEmpty) tags.set(TagField.genres, genres);
  }

  /// Album fields plus the fields of [track].
  void applyTrack(AudioTags tags, MbTrack track, {bool includeGenres = false}) {
    applyAlbumFields(tags, includeGenres: includeGenres);
    tags.setOne(TagField.title, track.title);
    tags.set(TagField.artists, track.artists.map((a) => a.name).toList());
    tags.set(TagField.musicBrainzArtistIds, track.artists.map((a) => a.id).nonNulls.toList());
    tags.setOne(TagField.musicBrainzRecordingId, track.recordingId);
    tags.setOne(TagField.musicBrainzReleaseTrackId, track.id);
    tags.setNumber(TagField.trackNumber, int.tryParse(track.number) ?? track.position);
    tags.setNumber(TagField.trackTotal, tracksOnDisc(track.discNumber));
    tags.setNumber(TagField.discNumber, track.discNumber);
  }

  /// Pairs local tracks with release tracks: disc+track number first, then
  /// title similarity, then position. Returns null for unmatched entries.
  List<MbTrack?> mapTracks(List<({String? title, int? disc, int? track, Duration? duration})> local) {
    final used = <MbTrack>{};
    final result = List<MbTrack?>.filled(local.length, null);
    for (var i = 0; i < local.length; i++) {
      final l = local[i];
      if (l.track == null) continue;
      final match = tracks.firstWhereOrNull(
        (t) => !used.contains(t) && t.discNumber == (l.disc ?? 1) && (int.tryParse(t.number) ?? t.position) == l.track,
      );
      // Only trust the number when the title or duration roughly agrees.
      if (match != null &&
          (l.title == null ||
              MatchScoring.similarity(l.title, match.title) > 0.5 ||
              (MatchScoring.durationScore(l.duration, match.length) ?? 0) > 0.8)) {
        result[i] = match;
        used.add(match);
      }
    }
    for (var i = 0; i < local.length; i++) {
      if (result[i] != null || local[i].title == null) continue;
      final best = tracks
          .where((t) => !used.contains(t))
          .map((t) => (t, MatchScoring.similarity(local[i].title, t.title)))
          .sortedBy<num>((e) => -e.$2)
          .firstOrNull;
      if (best != null && best.$2 >= 0.75) {
        result[i] = best.$1;
        used.add(best.$1);
      }
    }
    if (local.length == tracks.length) {
      final remaining = tracks.where((t) => !used.contains(t)).toList();
      for (var i = 0; i < local.length && remaining.isNotEmpty; i++) {
        if (result[i] == null) result[i] = remaining.removeAt(0);
      }
    }
    return result;
  }
}

/// MusicBrainz web service v2 (JSON), throttled to one request per second.
class MusicBrainzClient {
  MusicBrainzClient(this._http);

  final LookupHttp _http;

  static const _base = "https://musicbrainz.org/ws/2";

  static String _escape(String s) => s.replaceAllMapped(RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'), (m) => "\\${m[0]}");

  static String _query(Map<String, String?> fields) => fields.entries
      .where((e) => e.value != null && e.value!.trim().isNotEmpty)
      .map((e) => '${e.key}:"${_escape(e.value!.trim())}"')
      .join(" AND ");

  Future<List<MbRecordingCandidate>> searchRecordings(MatchQuery q, {int limit = 15}) async {
    final query = _query({"recording": q.title, "artist": q.artists.firstOrNull, "release": q.album});
    if (query.isEmpty) return const [];
    final json = await _http.getJson(
      Uri.parse("$_base/recording").replace(queryParameters: {"query": query, "fmt": "json", "limit": "$limit"}),
    );
    final results = parseRecordingSearch(json, q);
    // Fall back without the album: compilations and singles often miss it.
    if (results.isEmpty && q.album != null) {
      return searchRecordings(
        MatchQuery(title: q.title, artists: q.artists, duration: q.duration),
        limit: limit,
      );
    }
    return results;
  }

  static List<MbRecordingCandidate> parseRecordingSearch(dynamic json, MatchQuery q) {
    final list = [
      for (final r in ((json as Map?)?["recordings"] as List? ?? const []).cast<Map<String, dynamic>>())
        MbRecordingCandidate.parse(r)..score(q),
    ];
    return list..sort((a, b) => b.confidence.compareTo(a.confidence));
  }

  Future<List<MbReleaseCandidate>> searchReleases(MatchQuery q, {int? trackCount, int? year, int limit = 15}) async {
    final artist = q.albumArtists.firstOrNull ?? q.artists.firstOrNull;
    final query = _query({"release": q.album, "artist": artist});
    if (query.isEmpty) return const [];
    final json = await _http.getJson(
      Uri.parse("$_base/release").replace(queryParameters: {"query": query, "fmt": "json", "limit": "$limit"}),
    );
    return parseReleaseSearch(json, q, trackCount: trackCount, year: year);
  }

  static List<MbReleaseCandidate> parseReleaseSearch(dynamic json, MatchQuery q, {int? trackCount, int? year}) {
    final list = [
      for (final r in ((json as Map?)?["releases"] as List? ?? const []).cast<Map<String, dynamic>>())
        MbReleaseCandidate.parse(r)..score(q, trackCount: trackCount, year: year),
    ];
    return list..sort((a, b) => b.confidence.compareTo(a.confidence));
  }

  Future<MbRelease?> lookupRelease(String id) async {
    final json = await _http.getJson(
      Uri.parse(
        "$_base/release/$id",
      ).replace(queryParameters: {"inc": "recordings artist-credits release-groups genres", "fmt": "json"}),
    );
    return json == null ? null : MbRelease.parse(json as Map<String, dynamic>);
  }

  /// Recording lookup with its releases (used after an AcoustID hit).
  Future<MbRecordingCandidate?> lookupRecording(String id, MatchQuery q) async {
    final json = await _http.getJson(
      Uri.parse(
        "$_base/recording/$id",
      ).replace(queryParameters: {"inc": "artist-credits releases release-groups media", "fmt": "json"}),
    );
    return json == null ? null : (MbRecordingCandidate.parse(json as Map<String, dynamic>)..score(q));
  }
}
