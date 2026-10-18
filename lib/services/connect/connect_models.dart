library;

class ConnectDevice {
  const ConnectDevice({required this.name, required this.baseUrl});

  final String name;

  final String baseUrl;

  Uri endpoint(String path) => Uri.parse("$baseUrl/$path");

  @override
  bool operator ==(Object other) => other is ConnectDevice && other.baseUrl == baseUrl;

  @override
  int get hashCode => baseUrl.hashCode;

  @override
  String toString() => "ConnectDevice($name, $baseUrl)";
}

class ConnectStatus {
  const ConnectStatus({
    this.song,
    required this.state,
    required this.position,
    required this.volume,
    this.queueVersion,
    this.queueIndex,
    this.shuffle = false,
    this.repeat = "none",
  });

  final ConnectSong? song;

  final String state;

  final double position;
  final double volume;

  /// Changes whenever the device's queue does (see [ConnectQueue.versionOf]); null from devices older than the
  /// queue mirroring protocol.
  final String? queueVersion;

  /// The current track's index in the linear (unshuffled) queue.
  final int? queueIndex;

  final bool shuffle;

  /// `none`, `all` or `one`.
  final String repeat;

  bool get isPlaying => state == "playing";

  static const stopped = ConnectStatus(song: null, state: "stopped", position: 0, volume: 1);

  factory ConnectStatus.fromJson(Map<String, dynamic> json) => ConnectStatus(
    song: json["song"] == null ? null : ConnectSong.fromJson(json["song"] as Map<String, dynamic>),
    state: (json["state"] ?? "stopped") as String,
    position: ((json["position"] ?? 0) as num).toDouble(),
    volume: ((json["volume"] ?? 1) as num).toDouble(),
    queueVersion: json["queueVersion"] as String?,
    queueIndex: (json["queueIndex"] as num?)?.toInt(),
    shuffle: json["shuffle"] == true,
    repeat: (json["repeat"] as String?) ?? "none",
  );

  Map<String, dynamic> toJson() => {
    "song": song?.toJson(),
    "state": state,
    "position": position,
    "volume": volume,
    if (queueVersion != null) "queueVersion": queueVersion,
    if (queueIndex != null) "queueIndex": queueIndex,
    "shuffle": shuffle,
    "repeat": repeat,
  };
}

/// A device's whole queue, so a controller can mirror it and show it exactly as it is.
class ConnectQueue {
  const ConnectQueue({
    required this.items,
    required this.index,
    required this.position,
    this.shuffleOrder,
    this.nextUpLength = 0,
    this.playing = false,
    this.repeat = "none",
  });

  /// `BaseItemDto` JSON, in linear (unshuffled) order.
  final List<Map<String, dynamic>> items;

  /// The current track, as an index into [items].
  final int index;

  final double position;

  /// The play order as indices into [items], when shuffled.
  final List<int>? shuffleOrder;

  final int nextUpLength;
  final bool playing;
  final String repeat;

  bool get isEmpty => items.isEmpty;

  String get version => versionOf(items.map((i) => "${i["Id"]}"), shuffleOrder);

  /// Same ids in the same order (and the same shuffle) give the same version on every device.
  static String versionOf(Iterable<String> ids, List<int>? shuffleOrder) {
    var hash = 17;
    for (final id in ids) {
      hash = 0x1fffffff & (hash * 31 + id.hashCode);
    }
    for (final i in shuffleOrder ?? const <int>[]) {
      hash = 0x1fffffff & (hash * 31 + i);
    }
    return "${ids.length}-${shuffleOrder == null ? "l" : "s"}-${hash.toRadixString(16)}";
  }

  static ConnectQueue? tryParse(Map<String, dynamic>? json) {
    final raw = json?["items"];
    if (raw is! List) return null;
    final items = raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    final order = (json?["shuffleOrder"] as List?)?.map((e) => (e as num).toInt()).toList();
    return ConnectQueue(
      items: items,
      index: ((json?["index"] ?? 0) as num).toInt().clamp(0, items.isEmpty ? 0 : items.length - 1),
      position: ((json?["position"] ?? 0) as num).toDouble(),
      shuffleOrder: order != null && order.length == items.length ? order : null,
      nextUpLength: ((json?["nextUpLength"] ?? 0) as num).toInt(),
      playing: json?["playing"] != false,
      repeat: (json?["repeat"] as String?) ?? "none",
    );
  }

  Map<String, dynamic> toJson() => {
    "items": items,
    "index": index,
    "position": position,
    if (shuffleOrder != null) "shuffleOrder": shuffleOrder,
    "nextUpLength": nextUpLength,
    "playing": playing,
    "repeat": repeat,
  };
}

class ConnectSong {
  const ConnectSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.art,
  });

  final String id;
  final String title;
  final String artist;
  final String album;

  final double duration;

  final String? art;

  factory ConnectSong.fromJson(Map<String, dynamic> json) => ConnectSong(
    id: (json["id"] ?? "") as String,
    title: (json["title"] ?? "") as String,
    artist: (json["artist"] ?? "") as String,
    album: (json["album"] ?? "") as String,
    duration: ((json["duration"] ?? 0) as num).toDouble(),
    art: json["art"] as String?,
  );

  Map<String, dynamic> toJson() => {
    "id": id,
    "title": title,
    "artist": artist,
    "album": album,
    "duration": duration,
    "art": art,
  };
}

class ConnectCommand {
  const ConnectCommand(this.action, {this.position, this.volume, this.args = const {}});

  final String action;
  final double? position;
  final double? volume;

  /// Extra arguments of queue commands (`index`, `offset`, `items`, ...).
  final Map<String, dynamic> args;

  factory ConnectCommand.fromJson(Map<String, dynamic> json) => ConnectCommand(
    (json["action"] ?? "") as String,
    position: (json["position"] as num?)?.toDouble(),
    volume: (json["volume"] as num?)?.toDouble(),
    args: (json["args"] as Map?)?.cast<String, dynamic>() ?? const {},
  );

  Map<String, dynamic> toJson() => {
    "action": action,
    if (position != null) "position": position,
    if (volume != null) "volume": volume,
    if (args.isNotEmpty) "args": args,
  };
}

/// Accounts one device offers to another ("send my accounts to the TV"). The receiver decides whether to take them.
class SourceOffer {
  const SourceOffer({required this.profileName, required this.sources, this.from = ""});

  /// The profile on the receiving TV these accounts should land in.
  final String profileName;

  /// `MediaSourceConfig` storage maps (see `toTvOSStorageJson`).
  final List<Map<String, dynamic>> sources;

  final String from;

  static const maxSources = 20;

  static SourceOffer? tryParse(Map<String, dynamic>? json, {String from = ""}) {
    final raw = json?["sources"];
    if (raw is! List || raw.isEmpty || raw.length > maxSources) return null;
    final sources = raw.whereType<Map<String, dynamic>>().toList();
    if (sources.length != raw.length) return null;
    final name = (json?["profile"] as String?)?.trim() ?? "";
    return SourceOffer(profileName: name.isEmpty ? "Home" : name, sources: sources, from: from);
  }

  Map<String, dynamic> toJson() => {"profile": profileName, "sources": sources, "from": from};
}
