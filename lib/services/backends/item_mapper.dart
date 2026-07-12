import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';

class ItemMapper {
  ItemMapper(this.sourceId);

  final String sourceId;

  BaseItemId id(String nativeId) => BaseItemId.scoped(sourceId, nativeId);

  static int? ticks(Duration? d) => d == null ? null : d.inMicroseconds * 10;
  static Duration? seconds(num? s) => s == null ? null : Duration(milliseconds: (s * 1000).round());

  Map<dynamic, String>? _imageTag(bool hasImage, String nativeId) => hasImage ? {"Primary": nativeId} : null;

  List<NameIdPair>? _artistPair(String? name, String? artistNativeId) =>
      (name == null || artistNativeId == null) ? null : [NameIdPair(name: name, id: id(artistNativeId))];

  UserItemDataDto _userData(bool isFavorite) =>
      UserItemDataDto(isFavorite: isFavorite, playbackPositionTicks: 0, playCount: 0, played: false);

  List<MediaSourceInfo>? _mediaSources({
    required String nativeId,
    String? container,
    String? codec,
    int? size,
    int? bitrateKbps,
    int? sampleRate,
    int? bitDepth,
    int? channels,
    Duration? duration,
  }) {
    if (container == null && codec == null && size == null && bitrateKbps == null) return null;

    final bitrate = bitrateKbps == null ? null : bitrateKbps * 1000;

    return [
      MediaSourceInfo(
        id: id(nativeId),
        protocol: "Http",
        type: "Default",
        isRemote: true,
        supportsTranscoding: true,
        supportsDirectStream: true,
        supportsDirectPlay: true,
        isInfiniteStream: false,
        requiresOpening: false,
        requiresClosing: false,
        requiresLooping: false,
        supportsProbing: false,
        readAtNativeFramerate: false,
        ignoreDts: false,
        ignoreIndex: false,
        genPtsInput: false,
        container: container,
        size: size,
        bitrate: bitrate,
        runTimeTicks: ticks(duration),
        mediaStreams: [
          MediaStream(
            type: "Audio",
            index: 0,
            codec: codec ?? container,
            bitRate: bitrate,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            isDefault: true,
            isInterlaced: false,
            isForced: false,
            isExternal: false,
            isTextSubtitleStream: false,
            supportsExternalStream: false,
          ),
        ],
      ),
    ];
  }

  BaseItemDto track({
    required String nativeId,
    required String name,
    String? albumNativeId,
    String? album,
    String? artist,
    String? artistNativeId,
    int? indexNumber,
    int? parentIndexNumber,
    int? productionYear,
    Duration? duration,
    bool hasImage = false,
    bool isFavorite = false,
    String? container,
    String? codec,
    int? size,
    int? bitrateKbps,
    int? sampleRate,
    int? bitDepth,
    int? channels,
  }) => BaseItemDto(
    id: id(nativeId),
    name: name,
    type: BaseItemDtoType.track.jellyfinName,
    mediaType: "Audio",
    album: album,
    albumId: albumNativeId == null ? null : id(albumNativeId),
    albumArtist: artist,
    albumArtists: _artistPair(artist, artistNativeId),
    artistItems: _artistPair(artist, artistNativeId),
    artists: artist == null ? null : [artist],
    parentId: albumNativeId == null ? null : id(albumNativeId),
    indexNumber: indexNumber,
    parentIndexNumber: parentIndexNumber,
    productionYear: productionYear,
    runTimeTicks: ticks(duration),
    container: container,
    mediaSources: _mediaSources(
      nativeId: nativeId,
      container: container,
      codec: codec,
      size: size,
      bitrateKbps: bitrateKbps,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
      duration: duration,
    ),
    imageTags: _imageTag(hasImage, nativeId),
    userData: _userData(isFavorite),
  );

  BaseItemDto album({
    required String nativeId,
    required String name,
    String? artist,
    String? artistNativeId,
    int? productionYear,
    int? trackCount,
    Duration? duration,
    bool hasImage = false,
    bool isFavorite = false,
  }) => BaseItemDto(
    id: id(nativeId),
    name: name,
    type: BaseItemDtoType.album.jellyfinName,
    albumArtist: artist,
    albumArtists: _artistPair(artist, artistNativeId),
    artistItems: _artistPair(artist, artistNativeId),
    artists: artist == null ? null : [artist],
    parentId: artistNativeId == null ? null : id(artistNativeId),
    productionYear: productionYear,
    childCount: trackCount,
    runTimeTicks: ticks(duration),
    imageTags: _imageTag(hasImage, nativeId),
    userData: _userData(isFavorite),
  );

  BaseItemDto artist({
    required String nativeId,
    required String name,
    int? albumCount,
    bool hasImage = false,
    bool isFavorite = false,
  }) => BaseItemDto(
    id: id(nativeId),
    name: name,
    type: BaseItemDtoType.artist.jellyfinName,
    childCount: albumCount,
    imageTags: _imageTag(hasImage, nativeId),
    userData: _userData(isFavorite),
  );

  BaseItemDto playlist({
    required String nativeId,
    required String name,
    int? trackCount,
    Duration? duration,
    bool hasImage = false,
  }) => BaseItemDto(
    id: id(nativeId),
    name: name,
    type: BaseItemDtoType.playlist.jellyfinName,
    childCount: trackCount,
    runTimeTicks: ticks(duration),
    imageTags: _imageTag(hasImage, nativeId),
    userData: _userData(false),
  );

  BaseItemDto genre({required String name, int? albumCount}) =>
      BaseItemDto(id: id(name), name: name, type: BaseItemDtoType.genre.jellyfinName, childCount: albumCount);

  static String genreName(BaseItemId id) => id.nativeId;
}
