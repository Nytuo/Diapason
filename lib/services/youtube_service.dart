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

  Future<List<BaseItemDto>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    try {
      final results = await _yt.search.search(query);
      return results.map(_toItem).toList();
    } catch (e) {
      _log.warning("YouTube search for '$query' failed: $e");
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
