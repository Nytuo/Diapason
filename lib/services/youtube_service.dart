import 'dart:io';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:http/http.dart' as http;
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:logging/logging.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class YouTubeStream {
  const YouTubeStream(this.url, this.container);

  final Uri url;
  final String container;
}

class YouTubeService {
  static final _log = Logger("YouTubeService");

  static const sourceId = "yt";

  final YoutubeExplode _yt = YoutubeExplode();
  final ItemMapper _map = ItemMapper(sourceId);

  static const _blockCooldown = Duration(minutes: 10);

  DateTime? _blockedUntil;

  bool get isRateLimited => _blockedUntil != null && DateTime.now().isBefore(_blockedUntil!);

  static bool _looksLikeBlock(Object error) {
    final text = error.toString();
    return text.contains("google_abuse") ||
        text.contains("Redirect limit exceeded") ||
        text.contains("429") ||
        text.contains("consent");
  }

  Future<List<BaseItemDto>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final videoId = parseVideoId(trimmed);
    if (videoId != null) {
      final item = await videoById(videoId);
      return item == null ? const [] : [item];
    }

    if (isRateLimited) {
      _log.fine("Skipping YouTube search for '$query': blocked until $_blockedUntil");
      return const [];
    }

    try {
      final results = await _yt.search.search(trimmed);
      _blockedUntil = null;
      return results.map(_toItem).toList();
    } catch (e) {
      if (_looksLikeBlock(e)) {
        _blockedUntil = DateTime.now().add(_blockCooldown);
        _log.warning("YouTube is blocking searches; pausing them until $_blockedUntil");
      } else {
        _log.warning("YouTube search for '$query' failed: $e");
      }
      return const [];
    }
  }

  String? parseVideoId(String input) => VideoId.parseVideoId(input.trim());

  Future<BaseItemDto?> videoById(String idOrUrl) async {
    final id = parseVideoId(idOrUrl);
    if (id == null) return null;
    try {
      return _toItem(await _yt.videos.get(id));
    } catch (e) {
      _log.warning("Couldn't resolve YouTube video '$idOrUrl': $e");
      return null;
    }
  }

  Future<List<BaseItemDto>> relatedTracks(BaseItemDto item) async {
    try {
      final video = await _yt.videos.get(item.id.nativeId);
      final related = await _yt.videos.getRelatedVideos(video);
      if (related == null) return const [];
      return related.map(_toItem).toList();
    } catch (e) {
      _log.warning("Couldn't fetch related videos for '${item.name}': $e");
      return const [];
    }
  }

  BaseItemDto _toItem(Video video) => _map.track(
    nativeId: video.id.value,
    name: video.title,
    artist: video.author,
    duration: video.duration,
    hasImage: true,
  );

  Uri? thumbnail(BaseItemDto item) =>
      Uri.parse("https://i.ytimg.com/vi/${item.id.nativeId}/mqdefault.jpg");

  static final _streamClients = <(String, YoutubeApiClient)>[
    ("ANDROID_VR", YoutubeApiClient.androidVr),
    ("IOS", YoutubeApiClient.ios),
    ("MEDIA_CONNECT", YoutubeApiClient.mediaConnect),
    ("ANDROID", YoutubeApiClient.androidSdkless),
  ];

  Future<YouTubeStream?> streamUrl(BaseItemDto item) async {
    for (final audioOnly in [true, false]) {
      for (final (name, client) in _streamClients) {
        try {
          final manifest = await _yt.videos.streamsClient.getManifest(item.id.nativeId, ytClients: [client]);

          final audio = _playableFirst(manifest.audioOnly.sortByBitrate());
          final muxed = _playableFirst(manifest.muxed.sortByVideoQuality().reversed.toList());

          final stream = audio.isNotEmpty
              ? audio.first
              : (audioOnly || muxed.isEmpty ? null : muxed.first);

          if (stream == null) {
            _log.fine("$name has no ${audioOnly ? "audio-only" : ""} stream for '${item.name}'.");
            continue;
          }
          if (!await _isPlayable(stream.url)) {
            _log.fine("$name gave a URL for '${item.name}' that YouTube then refused; trying the next client.");
            continue;
          }

          final container = stream.container.name;
          _log.fine("Resolved '${item.name}' through $name as $container.");
          return YouTubeStream(stream.url, container);
        } catch (e) {
          _log.fine("$name could not resolve '${item.name}': $e");
        }
      }
    }

    _log.warning("No YouTube client could produce a playable stream for '${item.name}'.");
    return null;
  }

  List<T> _playableFirst<T extends StreamInfo>(List<T> streams) {
    if (!Platform.isIOS && !Platform.isMacOS) return streams;

    const decodable = {"mp4", "m4a"};
    final supported = streams.where((s) => decodable.contains(s.container.name.toLowerCase()));
    final rest = streams.where((s) => !decodable.contains(s.container.name.toLowerCase()));
    return [...supported, ...rest];
  }

  Future<bool> _isPlayable(Uri url) async {
    try {
      final response = await http.head(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 || response.statusCode == 206) return true;

      final ranged = await http
          .get(url, headers: {"Range": "bytes=0-0"})
          .timeout(const Duration(seconds: 5));
      return ranged.statusCode == 200 || ranged.statusCode == 206;
    } catch (e) {
      _log.fine("Could not check a YouTube URL: $e");
      return false;
    }
  }

  void dispose() => _yt.close();
}
