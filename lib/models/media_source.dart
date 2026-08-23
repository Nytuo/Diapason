import 'dart:convert';
import 'dart:math';

import 'package:isar/isar.dart';

import 'finamp_models.dart';

part 'media_source.g.dart';

enum MediaSourceKind {
  jellyfin,
  plex,
  subsonic,
  local,
  mpd,

  youtube;

  String get idPrefix => switch (this) {
    MediaSourceKind.jellyfin => "jf",
    MediaSourceKind.plex => "px",
    MediaSourceKind.subsonic => "sub",
    MediaSourceKind.local => "loc",
    MediaSourceKind.mpd => "mpd",
    MediaSourceKind.youtube => "yt",
  };

  bool get isConfigurable => this != MediaSourceKind.youtube;
}

class BackendCapabilities {
  const BackendCapabilities({
    this.transcoding = false,
    this.defaultTranscodingCodecs = const {},
    this.playlists = false,
    this.favorites = false,
    this.playbackReporting = false,
    this.instantMix = false,
    this.serverLyrics = false,
    this.search = true,
  });

  final bool transcoding;

  /// Codecs this backend can reliably transcode to without any extra,
  /// non-default server-side configuration (e.g. a custom Subsonic
  /// transcoding profile). Codecs outside this set may still work if the
  /// server happens to be configured for them, but shouldn't be assumed to.
  final Set<FinampTranscodingCodec> defaultTranscodingCodecs;

  final bool playlists;
  final bool favorites;
  final bool playbackReporting;
  final bool instantMix;
  final bool serverLyrics;
  final bool search;
}

class PlayableSource {
  const PlayableSource(this.uri, {this.headers = const {}, this.container});

  final Uri uri;
  final Map<String, String> headers;

  final String? container;

  bool get isLocalFile => uri.isScheme("file");

  @override
  String toString() => "PlayableSource($uri, headers: ${headers.keys.toList()}, container: $container)";
}

@collection
class MediaSourceConfig {
  MediaSourceConfig({
    required this.sourceId,
    required this.kind,
    required this.name,
    this.publicAddress = "",
    this.localAddress = "",
    this.preferLocalNetwork = false,
    this.isLocal = false,
    this.accessToken = "",
    this.username = "",
    this.password = "",
    this.userId = "",
    this.localPath = "",
    this.enabled = true,
  });

  Id get isarId => fastHash(sourceId);

  @Index(unique: true, replace: true)
  final String sourceId;

  @Enumerated(EnumType.name)
  final MediaSourceKind kind;

  String name;

  String publicAddress;
  String localAddress;
  bool preferLocalNetwork;
  bool isLocal;

  @ignore
  String get baseUrl => isLocal && preferLocalNetwork ? localAddress : publicAddress;

  String accessToken;

  String username;
  String password;

  String userId;

  String localPath;

  bool enabled;

  static String newSourceId(MediaSourceKind kind, Iterable<String> existing) {
    final rng = Random();
    while (true) {
      final candidate = "${kind.idPrefix}-${rng.nextInt(0xFFFFF).toRadixString(16).padLeft(5, '0')}";
      if (!existing.contains(candidate)) return candidate;
    }
  }

  static int fastHash(String string) {
    var hash = 0xcbf29ce484222325;
    for (var i = 0; i < string.length; i++) {
      final codeUnit = string.codeUnitAt(i);
      hash ^= codeUnit >> 8;
      hash *= 0x100000001b3;
      hash ^= codeUnit & 0xFF;
      hash *= 0x100000001b3;
    }
    return hash;
  }

  @override
  String toString() => "MediaSourceConfig($sourceId, ${kind.name}, $name)";

  Map<String, dynamic> toJson() => {
    "sourceId": sourceId,
    "kind": kind.name,
    "name": name,
    "publicAddress": publicAddress,
    "enabled": enabled,
  };

  String toJsonString() => jsonEncode(toJson());

  /// Full round-trip serialization used to persist configs in Hive on tvOS,
  /// where Isar has no native binary. See [MediaSourceService]'s tvOS branch.
  Map<String, dynamic> toTvOSStorageJson() => {
    "sourceId": sourceId,
    "kind": kind.name,
    "name": name,
    "publicAddress": publicAddress,
    "localAddress": localAddress,
    "preferLocalNetwork": preferLocalNetwork,
    "isLocal": isLocal,
    "accessToken": accessToken,
    "username": username,
    "password": password,
    "userId": userId,
    "localPath": localPath,
    "enabled": enabled,
  };

  factory MediaSourceConfig.fromTvOSStorageJson(Map<String, dynamic> json) => MediaSourceConfig(
    sourceId: json["sourceId"] as String,
    kind: MediaSourceKind.values.byName(json["kind"] as String),
    name: json["name"] as String,
    publicAddress: json["publicAddress"] as String? ?? "",
    localAddress: json["localAddress"] as String? ?? "",
    preferLocalNetwork: json["preferLocalNetwork"] as bool? ?? false,
    isLocal: json["isLocal"] as bool? ?? false,
    accessToken: json["accessToken"] as String? ?? "",
    username: json["username"] as String? ?? "",
    password: json["password"] as String? ?? "",
    userId: json["userId"] as String? ?? "",
    localPath: json["localPath"] as String? ?? "",
    enabled: json["enabled"] as bool? ?? true,
  );
}
