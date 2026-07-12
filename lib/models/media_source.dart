import 'dart:convert';
import 'dart:math';

import 'package:isar/isar.dart';

part 'media_source.g.dart';

enum MediaSourceKind {
  jellyfin,
  plex,
  subsonic,
  local,

  youtube;

  String get idPrefix => switch (this) {
    MediaSourceKind.jellyfin => "jf",
    MediaSourceKind.plex => "px",
    MediaSourceKind.subsonic => "sub",
    MediaSourceKind.local => "loc",
    MediaSourceKind.youtube => "yt",
  };

  bool get isConfigurable => this != MediaSourceKind.youtube;
}

class BackendCapabilities {
  const BackendCapabilities({
    this.transcoding = false,
    this.playlists = false,
    this.favorites = false,
    this.playbackReporting = false,
    this.instantMix = false,
    this.serverLyrics = false,
    this.search = true,
  });

  final bool transcoding;
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
}
