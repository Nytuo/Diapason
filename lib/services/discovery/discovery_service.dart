import 'dart:convert';
import 'dart:math';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class DiscoveredTrack {
  const DiscoveredTrack({required this.title, required this.artist, this.album});

  final String title;
  final String artist;
  final String? album;

  @override
  String toString() => "$artist - $title";
}

class FreshRelease {
  const FreshRelease({required this.title, required this.artist, this.date, this.mbid});

  final String title;
  final String artist;
  final String? date;
  final String? mbid;

  Uri? get coverUrl => mbid == null ? null : Uri.parse("https://coverartarchive.org/release-group/$mbid/front-250");
}

enum DiscoverPlaylistKind {
  listenBrainzPlaylist,

  lastFmTag,

  lastFmChart,
}

class DiscoverPlaylist {
  const DiscoverPlaylist({required this.id, required this.title, this.subtitle, required this.kind});

  final String id;
  final String title;
  final String? subtitle;
  final DiscoverPlaylistKind kind;
}

class DiscoveryService {
  DiscoveryService({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("DiscoveryService");
  static final _listenBrainz = Uri.parse("https://api.listenbrainz.org");
  static final _lastFm = Uri.parse("https://ws.audioscrobbler.com/2.0/");

  final http.Client _http;

  String get _lbToken => FinampSettingsHelper.finampSettings.listenBrainzToken;
  String get _lastFmKey => FinampSettingsHelper.finampSettings.lastFmApiKey;

  Future<List<FreshRelease>> freshReleases() async {
    final body = await _getJson(_listenBrainz.replace(path: "/1/explore/fresh-releases", queryParameters: {"days": "30"}));
    final releases = (body?["payload"]?["releases"] as List<dynamic>?) ?? const [];

    return releases
        .cast<Map<String, dynamic>>()
        .map(
          (r) => FreshRelease(
            title: (r["release_name"] ?? "Unknown") as String,
            artist: (r["artist_credit_name"] ?? "Unknown") as String,
            date: r["release_date"] as String?,
            mbid: r["release_group_mbid"] as String?,
          ),
        )
        .toList();
  }

  Future<List<DiscoveredTrack>> similarTracks({required String artist, required String title}) async {
    if (_lastFmKey.isEmpty) return const [];

    final body = await _getJson(
      _lastFm.replace(
        queryParameters: {
          "method": "track.getsimilar",
          "artist": artist,
          "track": title,
          "api_key": _lastFmKey,
          "format": "json",
          "limit": "25",
        },
      ),
    );
    final tracks = (body?["similartracks"]?["track"] as List<dynamic>?) ?? const [];

    return tracks
        .cast<Map<String, dynamic>>()
        .map(
          (t) => DiscoveredTrack(
            title: (t["name"] ?? "") as String,
            artist: (t["artist"]?["name"] ?? "") as String,
          ),
        )
        .where((t) => t.title.isNotEmpty && t.artist.isNotEmpty)
        .toList();
  }

  Future<List<({String name, double match})>> similarArtists(String artist) async {
    if (_lastFmKey.isEmpty || artist.isEmpty) return const [];

    final body = await _getJson(
      _lastFm.replace(
        queryParameters: {
          "method": "artist.getsimilar",
          "artist": artist,
          "api_key": _lastFmKey,
          "format": "json",
          "limit": "20",
        },
      ),
    );
    final artists = (body?["similarartists"]?["artist"] as List<dynamic>?) ?? const [];

    return artists
        .cast<Map<String, dynamic>>()
        .map(
          (a) => (
            name: (a["name"] ?? "") as String,
            match: double.tryParse("${a["match"] ?? 0}") ?? 0,
          ),
        )
        .where((a) => a.name.isNotEmpty)
        .toList();
  }

  Future<BaseItemDto?> findArtist(String name) async {
    final candidates = await GetIt.instance<AggregateBackend>().getItems(
      includeItemTypes: "MusicArtist",
      searchTerm: name,
      limit: 10,
    );
    final wanted = name.toLowerCase().trim();
    return candidates.where((a) => (a.name ?? "").toLowerCase().trim() == wanted).firstOrNull;
  }

  Future<List<({String mbid, String title})>> listenBrainzPlaylists(String username) async {
    final body = await _getJson(
      _listenBrainz.replace(path: "/1/user/$username/playlists"),
      token: _lbToken.isEmpty ? null : _lbToken,
    );
    final playlists = (body?["playlists"] as List<dynamic>?) ?? const [];

    return playlists
        .cast<Map<String, dynamic>>()
        .map((p) => p["playlist"] as Map<String, dynamic>?)
        .nonNulls
        .map((p) {
          final identifier = (p["identifier"] ?? "") as String;
          return (mbid: identifier.split("/").last, title: (p["title"] ?? "Untitled") as String);
        })
        .where((p) => p.mbid.isNotEmpty)
        .toList();
  }

  String? _cachedLbUsername;

  Future<String?> listenBrainzUsername() async {
    if (_cachedLbUsername != null) return _cachedLbUsername;
    if (_lbToken.isEmpty) return null;

    final body = await _getJson(_listenBrainz.replace(path: "/1/validate-token"), token: _lbToken);
    if (body?["valid"] != true) return null;
    final name = body?["user_name"] as String?;
    if (name == null || name.isEmpty) return null;
    return _cachedLbUsername = name;
  }

  Future<List<DiscoverPlaylist>> listenBrainzCreatedForYou(String username) async {
    final body = await _getJson(
      _listenBrainz.replace(path: "/1/user/$username/playlists/createdfor"),
      token: _lbToken.isEmpty ? null : _lbToken,
    );
    final playlists = (body?["playlists"] as List<dynamic>?) ?? const [];

    return playlists
        .cast<Map<String, dynamic>>()
        .map((p) => p["playlist"] as Map<String, dynamic>?)
        .nonNulls
        .map((p) {
          final identifier = (p["identifier"] ?? "") as String;
          return DiscoverPlaylist(
            id: identifier.split("/").last,
            title: (p["title"] ?? "Untitled") as String,
            subtitle: "Made for you by ListenBrainz",
            kind: DiscoverPlaylistKind.listenBrainzPlaylist,
          );
        })
        .where((p) => p.id.isNotEmpty)
        .toList();
  }

  Future<List<DiscoverPlaylist>> listenBrainzUserPlaylists(String username) async {
    final raw = await listenBrainzPlaylists(username);
    return raw
        .map(
          (p) => DiscoverPlaylist(
            id: p.mbid,
            title: p.title,
            subtitle: "Matched against your library, YouTube for the rest",
            kind: DiscoverPlaylistKind.listenBrainzPlaylist,
          ),
        )
        .toList();
  }

  List<DiscoverPlaylist> lastFmGenrePlaylists() {
    if (_lastFmKey.isEmpty) return const [];
    const genres = <({String tag, String title})>[
      (tag: "rock", title: "Rock"),
      (tag: "pop", title: "Pop"),
      (tag: "electronic", title: "Electronic"),
      (tag: "hip-hop", title: "Hip-Hop"),
      (tag: "jazz", title: "Jazz"),
      (tag: "metal", title: "Metal"),
      (tag: "indie", title: "Indie"),
      (tag: "classical", title: "Classical"),
      (tag: "r&b", title: "R&B"),
      (tag: "folk", title: "Folk"),
    ];
    return [
      const DiscoverPlaylist(
        id: "__chart__",
        title: "Global Top Tracks",
        subtitle: "Trending on Last.fm",
        kind: DiscoverPlaylistKind.lastFmChart,
      ),
      for (final g in genres)
        DiscoverPlaylist(
          id: g.tag,
          title: "Top ${g.title}",
          subtitle: "Popular on Last.fm",
          kind: DiscoverPlaylistKind.lastFmTag,
        ),
    ];
  }

  Future<List<DiscoveredTrack>> discoverPlaylistTracks(DiscoverPlaylist playlist) {
    switch (playlist.kind) {
      case DiscoverPlaylistKind.listenBrainzPlaylist:
        return listenBrainzPlaylistTracks(playlist.id);
      case DiscoverPlaylistKind.lastFmTag:
        return _lastFmTracks(method: "tag.gettoptracks", extra: {"tag": playlist.id});
      case DiscoverPlaylistKind.lastFmChart:
        return _lastFmTracks(method: "chart.gettoptracks");
    }
  }

  Future<List<DiscoveredTrack>> _lastFmTracks({required String method, Map<String, String> extra = const {}}) async {
    if (_lastFmKey.isEmpty) return const [];
    final body = await _getJson(
      _lastFm.replace(
        queryParameters: {
          "method": method,
          ...extra,
          "api_key": _lastFmKey,
          "format": "json",
          "limit": "50",
        },
      ),
    );
    final tracks = (body?["tracks"]?["track"] as List<dynamic>?) ?? const [];

    return tracks
        .cast<Map<String, dynamic>>()
        .map(
          (t) => DiscoveredTrack(
            title: (t["name"] ?? "") as String,
            artist: (t["artist"]?["name"] ?? "") as String,
          ),
        )
        .where((t) => t.title.isNotEmpty && t.artist.isNotEmpty)
        .toList();
  }

  Future<List<DiscoveredTrack>> listenBrainzPlaylistTracks(String mbid) async {
    final body = await _getJson(
      _listenBrainz.replace(path: "/1/playlist/$mbid"),
      token: _lbToken.isEmpty ? null : _lbToken,
    );
    final tracks = (body?["playlist"]?["track"] as List<dynamic>?) ?? const [];

    return tracks
        .cast<Map<String, dynamic>>()
        .map(
          (t) => DiscoveredTrack(
            title: (t["title"] ?? "") as String,
            artist: (t["creator"] ?? "") as String,
            album: t["album"] as String?,
          ),
        )
        .where((t) => t.title.isNotEmpty && t.artist.isNotEmpty)
        .toList();
  }

  Future<List<BaseItemDto?>> matchInLibrary(List<DiscoveredTrack> tracks, {int concurrency = 6}) async {
    final results = List<BaseItemDto?>.filled(tracks.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= tracks.length) return;
        results[index] = await _findInLibrary(tracks[index]);
      }
    }

    await Future.wait(List.generate(min(concurrency, tracks.length), (_) => worker()));
    return results;
  }

  Future<List<BaseItemDto>> youtubeCandidates(DiscoveredTrack track) async {
    final results = await GetIt.instance<YouTubeService>().search("${track.artist} ${track.title}");
    if (results.isEmpty) _log.fine("No YouTube results for '$track'");
    return results;
  }

  Future<BaseItemDto?> findOnYouTube(DiscoveredTrack track) async {
    final results = await youtubeCandidates(track);
    return results.firstOrNull;
  }

  Future<List<BaseItemDto>> resolve(List<DiscoveredTrack> tracks, {bool youtubeFallback = true}) async {
    final owned = await matchInLibrary(tracks);
    final resolved = <BaseItemDto>[];
    final youtube = GetIt.instance<YouTubeService>();

    for (var i = 0; i < tracks.length; i++) {
      final match = owned[i];
      if (match != null) {
        resolved.add(match);
        continue;
      }
      if (!youtubeFallback) continue;

      if (youtube.isRateLimited) continue;

      final fromYouTube = await findOnYouTube(tracks[i]);
      if (fromYouTube != null) resolved.add(fromYouTube);
    }

    return resolved;
  }

  Future<BaseItemDto?> _findInLibrary(DiscoveredTrack track) async {
    final candidates = await GetIt.instance<AggregateBackend>().getItems(
      includeItemTypes: "Audio",
      searchTerm: track.title,
      limit: 20,
    );

    final wantedTitle = track.title.toLowerCase().trim();
    final wantedArtist = track.artist.toLowerCase().trim();

    for (final candidate in candidates) {
      final title = (candidate.name ?? "").toLowerCase().trim();
      if (title != wantedTitle) continue;

      final artists = [
        candidate.albumArtist ?? "",
        ...?candidate.artists,
      ].map((a) => a.toLowerCase().trim());
      if (artists.any((a) => a == wantedArtist)) return candidate;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getJson(Uri url, {String? token}) async {
    try {
      final response = await _http.get(url, headers: {if (token != null) "Authorization": "Token $token"});
      if (response.statusCode != 200) {
        _log.fine("$url returned HTTP ${response.statusCode}");
        return null;
      }
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      _log.fine("$url failed: $e");
      return null;
    }
  }
}
