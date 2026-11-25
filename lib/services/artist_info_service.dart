import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What the public music databases know about an artist: its biography and origin, members and similar artists.
/// Mirrors the "About" panel of Chilpa's artist page.
class ArtistInfo {
  const ArtistInfo({
    this.mbid,
    this.bio,
    this.bioSource,
    this.bioUrl,
    this.type,
    this.begin,
    this.end,
    this.place,
    this.tags = const [],
    this.members = const [],
    this.similar = const [],
    this.labels = const [],
    this.portraitUrl,
    this.portraitCredit,
    this.portraitPage,
  });

  final String? mbid;
  final String? bio;
  final String? bioSource;
  final String? bioUrl;

  /// "Group", "Person", ...
  final String? type;
  final String? begin;
  final String? end;
  final String? place;
  final List<String> tags;
  final List<String> members;
  final List<String> similar;

  /// Labels the artist's releases came out on, most frequent first.
  final List<String> labels;

  /// A freely licensed portrait from Wikimedia Commons, with its credit line and page.
  final String? portraitUrl;
  final String? portraitCredit;
  final String? portraitPage;

  Map<String, Object?> toJson() => {
    "mbid": mbid,
    "bio": bio,
    "bioSource": bioSource,
    "bioUrl": bioUrl,
    "type": type,
    "begin": begin,
    "end": end,
    "place": place,
    "tags": tags,
    "members": members,
    "similar": similar,
    "labels": labels,
    "portraitUrl": portraitUrl,
    "portraitCredit": portraitCredit,
    "portraitPage": portraitPage,
  };

  factory ArtistInfo.fromJson(Map<String, dynamic> j) {
    List<String> list(String key) => ((j[key] as List?) ?? const []).whereType<String>().toList();
    return ArtistInfo(
      mbid: j["mbid"] as String?,
      bio: j["bio"] as String?,
      bioSource: j["bioSource"] as String?,
      bioUrl: j["bioUrl"] as String?,
      type: j["type"] as String?,
      begin: j["begin"] as String?,
      end: j["end"] as String?,
      place: j["place"] as String?,
      tags: list("tags"),
      members: list("members"),
      similar: list("similar"),
      labels: list("labels"),
      portraitUrl: j["portraitUrl"] as String?,
      portraitCredit: j["portraitCredit"] as String?,
      portraitPage: j["portraitPage"] as String?,
    );
  }

  bool get isEmpty =>
      bio == null &&
      type == null &&
      begin == null &&
      place == null &&
      tags.isEmpty &&
      members.isEmpty &&
      similar.isEmpty;
}

/// Fetches [ArtistInfo] from MusicBrainz (identity, origin, members, tags), Wikipedia through Wikidata (biography) and
/// ListenBrainz (similar artists). Only the artist's name goes out, nothing about the user or their library.
/// MusicBrainz asks for one request a second, so calls are spaced and results are kept for the session.
class ArtistInfoService {
  ArtistInfoService({http.Client? client}) : _client = client ?? http.Client();

  static final instance = ArtistInfoService();
  static final _log = Logger("ArtistInfoService");

  static const _agent = "Diapason (open-source music client)";
  final http.Client _client;
  final _cache = <String, Future<ArtistInfo>>{};
  Future<void> _queue = Future.value();

  /// How long a saved answer stays fresh: biographies and members change rarely.
  static const _maxAge = Duration(days: 30);

  Directory? _dir;

  Future<File?> _fileFor(String key) async {
    try {
      _dir ??= Directory(p.join((await getApplicationSupportDirectory()).path, "artist_info"));
      await _dir!.create(recursive: true);
      final safe = base64Url.encode(utf8.encode(key)).replaceAll("=", "");
      return File(p.join(_dir!.path, "${safe.length > 120 ? safe.substring(0, 120) : safe}.json"));
    } catch (_) {
      return null;
    }
  }

  Future<ArtistInfo?> _readDisk(String key) async {
    try {
      final file = await _fileFor(key);
      if (file == null || !file.existsSync()) return null;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final saved = DateTime.fromMillisecondsSinceEpoch((data["saved"] as num).toInt());
      if (DateTime.now().difference(saved) > _maxAge) return null;
      return ArtistInfo.fromJson(data["info"] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String key, ArtistInfo info) async {
    try {
      final file = await _fileFor(key);
      await file?.writeAsString(jsonEncode({"saved": DateTime.now().millisecondsSinceEpoch, "info": info.toJson()}));
    } catch (e) {
      _log.fine("Could not save artist info: $e");
    }
  }

  /// The info for [name]: from memory, else from the disk copy (so artists seen before open instantly, offline too),
  /// else fetched and saved.
  Future<ArtistInfo> infoFor(String name, {String? mbid}) {
    final key = "${mbid ?? ""}|${name.toLowerCase()}";
    return _cache[key] ??= _loadCached(key, name, mbid).catchError((Object e) {
      _log.fine("No artist info for $name: $e");
      _cache.remove(key);
      return const ArtistInfo();
    });
  }

  Future<ArtistInfo> _loadCached(String key, String name, String? mbid) async {
    final saved = await _readDisk(key);
    if (saved != null) return saved;
    final info = await _load(name, mbid);
    // Only a real answer is kept: an empty one (unknown artist, ambiguous name) is tried again next time.
    if (!info.isEmpty) unawaited(_writeDisk(key, info));
    return info;
  }

  /// A MusicBrainz call, queued behind the previous one (at least a second apart). MusicBrainz answers 503 when it
  /// is busy or the pace is exceeded, so a refused call is retried a few times with a growing wait.
  Future<Map<String, dynamic>?> _musicBrainz(String path) {
    final completer = Completer<Map<String, dynamic>?>();
    _queue = _queue.then((_) async {
      Map<String, dynamic>? result;
      for (var attempt = 0; attempt < 4 && result == null; attempt++) {
        if (attempt > 0) await Future<void>.delayed(Duration(seconds: 2 * attempt));
        try {
          result = await _json("https://musicbrainz.org/ws/2/$path");
        } catch (e) {
          _log.fine("MusicBrainz request failed: $e");
        }
      }
      completer.complete(result);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    });
    return completer.future;
  }

  Future<Map<String, dynamic>?> _json(String url) async {
    final response = await _client
        .get(Uri.parse(url), headers: {"User-Agent": _agent, "Accept": "application/json"})
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : {"list": decoded};
  }

  static String _plain(String text) => text.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), "");

  Future<ArtistInfo> _load(String name, String? knownMbid) async {
    var mbid = knownMbid;
    if (mbid == null) {
      final found = await _musicBrainz(
        "artist?query=${Uri.encodeQueryComponent('artist:"${name.replaceAll('"', '')}"')}&fmt=json&limit=5",
      );
      // A failed search must not be cached as "no such artist": throw, so the next visit tries again.
      if (found == null) throw StateError("MusicBrainz search failed");
      final artists = (found["artists"] as List?) ?? const [];
      // Only a confident, unambiguous match: several artists with the same name would give the wrong biography.
      final exact = artists
          .whereType<Map<String, dynamic>>()
          .where((a) => (a["score"] as num? ?? 0) >= 95 && _plain(a["name"] as String? ?? "") == _plain(name))
          .toList();
      if (exact.length != 1) return const ArtistInfo();
      mbid = exact.first["id"] as String?;
    }
    if (mbid == null) return const ArtistInfo();

    final detail = await _musicBrainz("artist/$mbid?inc=url-rels+artist-rels+tags&fmt=json");
    if (detail == null) throw StateError("MusicBrainz lookup failed");

    final life = detail["life-span"] as Map<String, dynamic>? ?? const {};
    final area = (detail["begin-area"] ?? detail["area"]) as Map<String, dynamic>?;
    final relations = (detail["relations"] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
    final members = [
      for (final r in relations)
        if (r["type"] == "member of band" && r["direction"] == "backward" && r["ended"] != true)
          (r["artist"] as Map<String, dynamic>?)?["name"] as String?,
    ].whereType<String>().toSet().take(12).toList();
    final tags = ((detail["tags"] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((t) => (t["count"] as num? ?? 0) > 0)
        .map((t) => t["name"] as String)
        .take(6)
        .toList();

    final results = await Future.wait([_wikidata(relations), _similar(mbid), _labels(mbid)]);
    final wiki = results[0] as _WikiInfo?;
    final similar = results[1] as List<String>;
    final labels = results[2] as List<String>;
    return ArtistInfo(
      mbid: mbid,
      bio: wiki?.text,
      bioSource: wiki?.text == null ? null : "Wikipedia",
      bioUrl: wiki?.url,
      portraitUrl: wiki?.portrait,
      portraitCredit: wiki?.credit,
      portraitPage: wiki?.portraitPage,
      labels: labels,
      type: detail["type"] as String?,
      begin: life["begin"] as String?,
      end: life["ended"] == true ? life["end"] as String? : null,
      place: area?["name"] as String? ?? (detail["country"] as String?),
      tags: tags,
      members: members,
      similar: similar,
    );
  }

  /// The artist's Wikidata entity: its Wikipedia summary (biography) and its Commons portrait. Like Chilpa, only an
  /// identity-linked image is used, never a name-only image search.
  Future<_WikiInfo?> _wikidata(List<Map<String, dynamic>> relations) async {
    final entities = <String>{};
    for (final r in relations) {
      if (r["type"] != "wikidata") continue;
      final resource = (r["url"] as Map<String, dynamic>?)?["resource"] as String?;
      const prefix = "https://www.wikidata.org/wiki/";
      if (resource != null && resource.startsWith(prefix)) entities.add(resource.substring(prefix.length));
    }
    if (entities.length != 1 || !RegExp(r"^Q\d+$").hasMatch(entities.first)) return null;
    final entity = entities.first;
    try {
      final data = await _json(
        "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=$entity&props=claims|sitelinks&sitefilter=enwiki&format=json",
      );
      final item = (data?["entities"] as Map<String, dynamic>?)?[entity] as Map<String, dynamic>?;
      final (bio, bioUrl) = await _summary(item) ?? (null, null);
      final portrait = await _portrait(item);
      if (bio == null && portrait == null) return null;
      return _WikiInfo(
        text: bio,
        url: bioUrl,
        portrait: portrait?.url,
        credit: portrait?.credit,
        portraitPage: portrait?.page,
      );
    } catch (_) {
      return null;
    }
  }

  Future<(String, String)?> _summary(Map<String, dynamic>? item) async {
    final title = ((item?["sitelinks"] as Map?)?["enwiki"] as Map?)?["title"] as String?;
    if (title == null) return null;
    final summary = await _json(
      "https://en.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(title.replaceAll(' ', '_'))}",
    );
    final extract = summary?["extract"] as String?;
    if (extract == null || extract.trim().isEmpty || summary?["type"] == "disambiguation") return null;
    final url = ((summary?["content_urls"] as Map?)?["desktop"] as Map?)?["page"] as String?;
    return (extract.trim(), url ?? "https://en.wikipedia.org/wiki/${Uri.encodeComponent(title)}");
  }

  Future<({String url, String credit, String page})?> _portrait(Map<String, dynamic>? item) async {
    final claims = (item?["claims"] as Map?)?["P18"] as List?;
    if (claims == null || claims.isEmpty) return null;
    final best =
        claims.cast<Map<String, dynamic>>().where((c) => c["rank"] == "preferred").firstOrNull ??
        claims.cast<Map<String, dynamic>>().firstWhere((c) => c["rank"] == "normal", orElse: () => const {});
    final file = ((best["mainsnak"] as Map?)?["datavalue"] as Map?)?["value"] as String?;
    if (file == null || file.isEmpty || file.length > 512) return null;
    final info = await _json(
      "https://commons.wikimedia.org/w/api.php?action=query&titles=${Uri.encodeQueryComponent("File:$file")}"
      "&prop=imageinfo&iiprop=url|extmetadata&iiurlwidth=600&format=json&formatversion=2",
    );
    final pages = (info?["query"] as Map?)?["pages"] as List?;
    final imageInfo = ((pages?.firstOrNull as Map?)?["imageinfo"] as List?)?.firstOrNull as Map?;
    final thumb = imageInfo?["thumburl"] as String?;
    if (thumb == null ||
        !(thumb.startsWith("https://upload.wikimedia.org/wikipedia/commons/") ||
            thumb.startsWith("https://thumb.wikimedia.org/wikipedia/commons/"))) {
      return null;
    }
    String field(String key) =>
        _plainText(((imageInfo?["extmetadata"] as Map?)?[key] as Map?)?["value"] as String? ?? "");
    final credit = [field("Artist"), field("LicenseShortName")].where((t) => t.isNotEmpty).join(" · ");
    return (
      url: thumb,
      credit: credit,
      page:
          imageInfo?["descriptionurl"] as String? ??
          "https://commons.wikimedia.org/wiki/File:${Uri.encodeComponent(file)}",
    );
  }

  /// Commons metadata is HTML: strip it to plain text for the credit line.
  static String _plainText(String html) =>
      html.replaceAll(RegExp(r"<[^>]*>"), " ").replaceAll("&amp;", "&").replaceAll(RegExp(r"\s+"), " ").trim();

  /// The labels this artist's releases came out on, most frequent first.
  Future<List<String>> _labels(String mbid) async {
    final data = await _musicBrainz("release?artist=$mbid&inc=labels&fmt=json&limit=100");
    final counts = <String, int>{};
    for (final release in ((data?["releases"] as List?) ?? const []).whereType<Map<String, dynamic>>()) {
      for (final info in ((release["label-info"] as List?) ?? const []).whereType<Map<String, dynamic>>()) {
        final name = (info["label"] as Map?)?["name"] as String?;
        if (name != null && name.isNotEmpty && name != "[no label]") counts[name] = (counts[name] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(8).map((e) => e.key).toList();
  }

  /// Artists listeners of this one also play, from ListenBrainz's open similarity data.
  Future<List<String>> _similar(String mbid) async {
    try {
      const algorithm = "session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30";
      final data = await _json(
        "https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids=$mbid&algorithm=$algorithm",
      );
      final rows = (data?["list"] as List?) ?? const [];
      return rows
          .whereType<Map<String, dynamic>>()
          .where((r) => r["artist_mbid"] != mbid) // the artist itself can come back as a row
          .map((r) => r["name"] as String?)
          .whereType<String>()
          .take(8)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

final artistInfoProvider = FutureProvider.autoDispose.family<ArtistInfo, String>(
  (ref, name) => ArtistInfoService.instance.infoFor(name),
);

class _WikiInfo {
  const _WikiInfo({this.text, this.url, this.portrait, this.credit, this.portraitPage});

  final String? text;
  final String? url;
  final String? portrait;
  final String? credit;
  final String? portraitPage;
}
