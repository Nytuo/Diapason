import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/services/youtube_service.dart';

/// A [YouTubeService] whose answers the test decides, with no yt-dlp behind it.
class StubYouTube extends YouTubeService {
  YouTubeSource route = YouTubeSource.uploader;
  Future<List<BaseItemDto>> Function(String query) onSearch = (_) async => const [];
  Future<List<BaseItemDto>> Function(BaseItemDto seed) onRelated = (_) async => const [];
  final queries = <String>[];
  final relatedAsked = <String>[];

  @override
  YouTubeSource get source => route;

  @override
  Future<List<BaseItemDto>> search(String query, {bool throwOnError = false}) {
    queries.add(query);
    return onSearch(query);
  }

  @override
  Future<List<BaseItemDto>> relatedTracks(BaseItemDto item) {
    relatedAsked.add(item.id.nativeId);
    return onRelated(item);
  }

  @override
  Uri? thumbnail(BaseItemDto item) => null;
}

/// A YouTube track as the app would hold it.
BaseItemDto ytTrack(String id, String title, [String artist = 'Artist']) => ItemMapper(
  YouTubeService.sourceId,
).track(nativeId: id, name: title, artist: artist, duration: const Duration(seconds: 125));
