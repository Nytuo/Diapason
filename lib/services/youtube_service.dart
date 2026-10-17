import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/yt_entry.dart';
import 'package:diapason/services/youtube/ytdlp_errors.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

class YouTubeStream {
  const YouTubeStream(this.url, this.container, {this.headers = const {}});

  final Uri url;
  final String? container;

  final Map<String, String> headers;
}

class YouTubeShelf {
  const YouTubeShelf(this.title, this.tracks);

  final String title;
  final List<BaseItemDto> tracks;
}

class YouTubeUnavailable extends AppException {
  const YouTubeUnavailable(super.message) : super(source: ErrorSource.ytdlp, code: "youtube_unavailable");
}

class YouTubeService {
  static final _log = Logger("YouTubeService");

  static const sourceId = "yt";

  final ItemMapper _map = ItemMapper(sourceId);

  UploaderClient get _uploader => GetIt.instance<UploaderClient>();
  LocalYtDlpService get _local => GetIt.instance<LocalYtDlpService>();
  YouTubeAvailability get _availability => GetIt.instance<YouTubeAvailability>();

  YouTubeSource get source => _availability.source;

  bool get usesProxy => source == YouTubeSource.uploader;

  Map<String, String> get imageHeaders => usesProxy ? _uploader.authHeaders : const {};

  static const _blockCooldown = Duration(minutes: 10);
  DateTime? _blockedUntil;

  bool get isRateLimited => _blockedUntil != null && DateTime.now().isBefore(_blockedUntil!);

  void _noteFailure(Object error) {
    final code = error is AppException ? error.code : null;
    if (code == YtFailureKind.rateLimited.code ||
        code == YtFailureKind.blocked.code ||
        code == "youtube_rate_limited" ||
        code == "youtube_blocked") {
      _blockedUntil = DateTime.now().add(_blockCooldown);
      _log.warning("YouTube is pushing back ($code); pausing background lookups until $_blockedUntil");
    }
  }

  Future<T> _viaSource<T>(
    String what, {
    required Future<T> Function(LocalYtDlpService local) local,
    required Future<T> Function(UploaderClient uploader) uploader,
  }) async {
    try {
      switch (source) {
        case YouTubeSource.local:
          return await local(_local);
        case YouTubeSource.uploader:
          return await uploader(_uploader);
        case YouTubeSource.none:
          final problems = GetIt.instance<YouTubeAvailability>().status.value.problems;
          throw YouTubeUnavailable(
            problems.isEmpty ? "YouTube isn't set up yet." : "YouTube isn't available: ${problems.join(" ")}",
          );
      }
    } catch (e, stack) {
      _noteFailure(e);
      _log.warning("YouTube $what failed via ${source.name}: ${e is AppException ? e.technical : e}", e, stack);
      rethrow;
    }
  }

  BaseItemDto _toItem(YtEntry e) => _map.track(
    nativeId: e.id,
    name: e.title,
    artist: e.artist,
    duration: e.durationSecs > 0 ? Duration(seconds: e.durationSecs) : null,
    hasImage: true,
  );

  Future<List<BaseItemDto>> search(String query, {bool throwOnError = false}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    try {
      final id = parseVideoId(trimmed);
      if (id != null) {
        final item = await videoById(id, throwOnError: true);
        return item == null ? const [] : [item];
      }
      final limit = FinampSettingsHelper.finampSettings.youtubeResultCount.clamp(5, 50);
      final entries = await _viaSource(
        "search",
        local: (l) => l.search(trimmed, limit: limit),
        uploader: (u) => u.ytSearch(trimmed, limit: limit),
      );
      return entries.map(_toItem).toList();
    } catch (_) {
      if (throwOnError) rethrow;
      return const [];
    }
  }

  String? parseVideoId(String input) => LocalYtDlpService.parseVideoId(input);

  Future<BaseItemDto?> videoById(String idOrUrl, {bool throwOnError = false}) async {
    final id = parseVideoId(idOrUrl);
    if (id == null) return null;
    try {
      final entry = await _viaSource(
        "lookup",
        local: (l) => l.lookup(id),
        uploader: (u) async => (await u.ytSearch(id, limit: 1)).firstOrNull,
      );
      return entry == null ? null : _toItem(entry);
    } catch (_) {
      if (throwOnError) rethrow;
      return null;
    }
  }

  Future<List<BaseItemDto>> relatedTracks(BaseItemDto item) async {
    try {
      final id = item.id.nativeId;
      final entries = await _viaSource("related", local: (l) => l.related(id), uploader: (u) => u.ytRelated(id));
      return entries.map(_toItem).toList();
    } catch (_) {
      return const [];
    }
  }

  Uri? thumbnail(BaseItemDto item) => usesProxy
      ? _uploader.ytThumbnail(item.id.nativeId)
      : Uri.parse("https://i.ytimg.com/vi/${item.id.nativeId}/mqdefault.jpg");

  Future<YouTubeStream?> streamUrl(BaseItemDto item) async {
    final id = item.id.nativeId;
    try {
      return await _viaSource<YouTubeStream>(
        "stream '${item.name}'",
        local: (l) async {
          final s = await l.streamUrl(id);
          return YouTubeStream(s.url, s.ext);
        },

        uploader: (u) async => YouTubeStream(u.ytStream(id), null, headers: u.authHeaders),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> explainStreamFailure(BaseItemDto item) async {
    try {
      await _viaSource<void>(
        "probe '${item.name}'",
        local: (l) => l.streamUrl(item.id.nativeId),
        uploader: (u) async {
          final caps = await u.capabilities();
          if (!caps.reachable) throw UploaderException(caps.problem ?? "The uploader can't be reached.");
          if (!caps.ytdlp) throw const YouTubeUnavailable("The uploader's YouTube feature is off.");
        },
      );
      return null;
    } catch (e) {
      return FriendlyError.message(e);
    }
  }

  static const _chartUrl = "https://www.youtube.com/playlist?list=PL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i";
  static const _newMusicQuery = "new music this week official audio";
  static const _shelfTtl = Duration(minutes: 20);

  List<YouTubeShelf>? _shelves;
  DateTime? _shelvesAt;
  YouTubeSource? _shelvesSource;
  String? _shelvesKey;

  String get _shelfSettingsKey {
    final s = FinampSettingsHelper.finampSettings;
    return "${s.youtubeShowHits}/${s.youtubeShowNew}";
  }

  Future<List<YouTubeShelf>> homeShelves({bool refresh = false}) async {
    final fresh =
        _shelves != null &&
        _shelvesAt != null &&
        _shelvesSource == source &&
        _shelvesKey == _shelfSettingsKey &&
        DateTime.now().difference(_shelvesAt!) < _shelfTtl;
    if (!refresh && fresh) return _shelves!;

    final settings = FinampSettingsHelper.finampSettings;
    final results = await Future.wait([
      settings.youtubeShowHits ? _hits() : Future.value(const <BaseItemDto>[]),
      settings.youtubeShowNew ? _newReleases() : Future.value(const <BaseItemDto>[]),
    ]);
    final shelves = [
      if (results[0].isNotEmpty) YouTubeShelf("Hits on YouTube", results[0]),
      if (results[1].isNotEmpty) YouTubeShelf("New this week", results[1]),
    ];
    if (shelves.isNotEmpty) {
      _shelves = shelves;
      _shelvesAt = DateTime.now();
      _shelvesSource = source;
      _shelvesKey = _shelfSettingsKey;
    }
    return shelves;
  }

  Future<List<BaseItemDto>> _hits() async {
    try {
      final entries = await _viaSource(
        "hits",
        local: (l) => l.playlist(_chartUrl, limit: 30),
        uploader: (u) => u.ytTrending(limit: 30),
      );
      return entries.map(_toItem).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<BaseItemDto>> _newReleases() async {
    try {
      final entries = await _viaSource(
        "new releases",
        local: (l) => l.search(_newMusicQuery),
        uploader: (u) => u.ytSearch(_newMusicQuery, limit: 20),
      );
      return entries.map(_toItem).toList();
    } catch (_) {
      return const [];
    }
  }

  void dispose() {}
}
