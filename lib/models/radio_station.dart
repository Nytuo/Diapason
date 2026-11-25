import 'package:diapason/models/jellyfin_models.dart';

/// An internet radio station: either one from the Radio Browser directory
/// (https://www.radio-browser.info) or one the user added by its stream URL.
///
/// Stations are kept as small JSON strings in Hive (see `RadioStationStore`),
/// which works on every platform including tvOS, where Isar is unavailable.
class RadioStation {
  RadioStation({
    required this.id,
    required this.name,
    required this.streamUrl,
    this.homepage,
    this.faviconUrl,
    this.country,
    this.countryCode,
    this.language,
    this.tags = const [],
    this.codec,
    this.bitrate,
    this.isHls = false,
    this.votes,
    this.clickCount,
    this.isCustom = false,
  });

  /// Radio Browser's `stationuuid` for directory stations, or a locally
  /// generated `custom-<uuid>` id for stations the user added themselves.
  final String id;
  final String name;

  /// Stream URL. For directory stations this is `url_resolved` when known
  /// (the playlist already followed), otherwise `url`. It may still be a
  /// .pls/.m3u playlist; it is resolved again right before playback.
  final String streamUrl;
  final String? homepage;
  final String? faviconUrl;
  final String? country;
  final String? countryCode;
  final String? language;
  final List<String> tags;
  final String? codec;

  /// Bitrate in kbps; 0 or null when unknown.
  final int? bitrate;
  final bool isHls;
  final int? votes;
  final int? clickCount;
  final bool isCustom;

  /// The [BaseItemId.sourceId] all radio station items live under.
  static const sourceId = "radio";

  static const _faviconKey = "RadioFavicon";
  static const _directoryKey = "RadioBrowser";
  static const _hlsKey = "RadioHls";
  static const _homepageKey = "RadioHomepage";

  /// Whether [item] is a live stream (an internet radio station from this
  /// directory, the user's own stations, or a server's radio station).
  static bool isLiveItem(BaseItemDto? item) => (item?.isLive ?? false) || item?.id.sourceId == sourceId;

  /// Whether [item] is one of Diapason's own radio stations (directory or custom).
  static bool isStationItem(BaseItemDto? item) => item?.id.sourceId == sourceId;

  bool get isDirectoryStation => !isCustom;

  /// "MP3 · 128 kbps" style summary; empty when nothing is known.
  String get formatLabel {
    final parts = <String>[
      if (isHls) "HLS",
      if ((codec ?? "").isNotEmpty && codec!.toUpperCase() != "UNKNOWN") codec!.toUpperCase(),
      if ((bitrate ?? 0) > 0) "$bitrate kbps",
    ];
    return parts.join(" · ");
  }

  RadioStation copyWith({
    String? name,
    String? streamUrl,
    String? homepage,
    String? faviconUrl,
    List<String>? tags,
    String? country,
  }) => RadioStation(
    id: id,
    name: name ?? this.name,
    streamUrl: streamUrl ?? this.streamUrl,
    homepage: homepage ?? this.homepage,
    faviconUrl: faviconUrl ?? this.faviconUrl,
    country: country ?? this.country,
    countryCode: countryCode,
    language: language,
    tags: tags ?? this.tags,
    codec: codec,
    bitrate: bitrate,
    isHls: isHls,
    votes: votes,
    clickCount: clickCount,
    isCustom: isCustom,
  );

  /// Parses one station object as returned by the Radio Browser API
  /// (`/json/stations/...`). Returns null for entries without a name or URL.
  static RadioStation? fromRadioBrowserJson(Map<String, dynamic> json) {
    String? str(String key) {
      final value = json[key];
      if (value == null) return null;
      final s = value.toString().trim();
      return s.isEmpty ? null : s;
    }

    int? integer(String key) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value.trim());
      return null;
    }

    bool flag(String key) {
      final value = json[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) return value == "1" || value.toLowerCase() == "true";
      return false;
    }

    final uuid = str("stationuuid");
    final name = str("name");
    final url = str("url_resolved") ?? str("url");
    if (uuid == null || name == null || url == null) return null;

    return RadioStation(
      id: uuid,
      name: name,
      streamUrl: url,
      homepage: str("homepage"),
      faviconUrl: str("favicon"),
      country: str("country"),
      countryCode: str("countrycode"),
      language: str("language"),
      tags: (str("tags") ?? "").split(",").map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
      codec: str("codec"),
      bitrate: integer("bitrate"),
      isHls: flag("hls"),
      votes: integer("votes"),
      clickCount: integer("clickcount"),
    );
  }

  /// Parses a Radio Browser station list response, skipping invalid entries.
  static List<RadioStation> listFromRadioBrowserJson(Object? json) {
    if (json is! List) return const [];
    return json
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => fromRadioBrowserJson(e.cast<String, dynamic>()))
        .nonNulls
        .toList();
  }

  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "streamUrl": streamUrl,
    "homepage": ?homepage,
    "faviconUrl": ?faviconUrl,
    "country": ?country,
    "countryCode": ?countryCode,
    "language": ?language,
    "tags": tags,
    "codec": ?codec,
    "bitrate": ?bitrate,
    "isHls": isHls,
    "votes": ?votes,
    "clickCount": ?clickCount,
    "isCustom": isCustom,
  };

  factory RadioStation.fromJson(Map<String, dynamic> json) => RadioStation(
    id: json["id"] as String,
    name: json["name"] as String,
    streamUrl: json["streamUrl"] as String,
    homepage: json["homepage"] as String?,
    faviconUrl: json["faviconUrl"] as String?,
    country: json["country"] as String?,
    countryCode: json["countryCode"] as String?,
    language: json["language"] as String?,
    tags: (json["tags"] as List?)?.cast<String>() ?? const [],
    codec: json["codec"] as String?,
    bitrate: json["bitrate"] as int?,
    isHls: json["isHls"] as bool? ?? false,
    votes: json["votes"] as int?,
    clickCount: json["clickCount"] as int?,
    isCustom: json["isCustom"] as bool? ?? false,
  );

  /// The queue/player item for this station: a live "track" whose album is the
  /// station name, so the player keeps showing the station while ICY
  /// now-playing metadata replaces the title and artist.
  BaseItemDto toBaseItem({bool isFavorite = false}) => BaseItemDto(
    id: BaseItemId.scoped(sourceId, id),
    name: name,
    type: "Audio",
    mediaType: "Audio",
    album: name,
    albumArtist: name,
    isLive: true,
    path: streamUrl,
    container: isHls ? "hls" : codec?.toLowerCase(),
    imageTags: (faviconUrl ?? "").isEmpty ? null : {"Primary": faviconUrl.hashCode.toRadixString(16)},
    providerIds: {
      _faviconKey: ?faviconUrl,
      if (isDirectoryStation) _directoryKey: id,
      if (isHls) _hlsKey: "1",
      _homepageKey: ?homepage,
    },
    genres: tags.isEmpty ? null : tags.take(3).toList(),
    userData: UserItemDataDto(isFavorite: isFavorite, playbackPositionTicks: 0, playCount: 0, played: false),
  );

  /// The favicon of a station item made by [toBaseItem].
  static Uri? faviconOf(BaseItemDto item) {
    final url = item.providerIds?[_faviconKey];
    return url is String ? Uri.tryParse(url) : null;
  }

  /// Whether a station item made by [toBaseItem] came from Radio Browser, and
  /// so should be counted with its click endpoint when played.
  static String? directoryUuidOf(BaseItemDto item) {
    final uuid = item.providerIds?[_directoryKey];
    return uuid is String ? uuid : null;
  }

  static bool isHlsItem(BaseItemDto item) => item.providerIds?[_hlsKey] == "1" || item.container == "hls";

  /// Rebuilds the station from an item made by [toBaseItem] (e.g. a restored
  /// queue entry whose station is not saved).
  static RadioStation? fromBaseItem(BaseItemDto item) {
    if (!isStationItem(item) || (item.path ?? "").isEmpty) return null;
    final directory = directoryUuidOf(item);
    final homepage = item.providerIds?[_homepageKey];
    return RadioStation(
      id: item.id.nativeId,
      name: item.album ?? item.name ?? "Radio",
      streamUrl: item.path!,
      faviconUrl: faviconOf(item)?.toString(),
      homepage: homepage is String ? homepage : null,
      codec: item.container == "hls" ? null : item.container,
      isHls: isHlsItem(item),
      tags: item.genres ?? const [],
      isCustom: directory == null,
    );
  }
}

/// A country, language or tag as listed by Radio Browser, with its station count.
class RadioBrowserCategory {
  const RadioBrowserCategory({required this.name, this.code, this.stationCount = 0});

  final String name;

  /// ISO 3166-1 country code for countries, ISO 639 code for languages.
  final String? code;
  final int stationCount;

  static List<RadioBrowserCategory> listFromJson(Object? json, {String? codeKey}) {
    if (json is! List) return const [];
    final result = <RadioBrowserCategory>[];
    for (final entry in json.whereType<Map<dynamic, dynamic>>()) {
      final name = entry["name"]?.toString().trim() ?? "";
      if (name.isEmpty) continue;
      final count = entry["stationcount"];
      final code = codeKey == null ? null : entry[codeKey]?.toString().trim();
      result.add(
        RadioBrowserCategory(
          name: name,
          code: (code ?? "").isEmpty ? null : code,
          stationCount: count is num ? count.toInt() : int.tryParse("$count") ?? 0,
        ),
      );
    }
    return result;
  }
}
