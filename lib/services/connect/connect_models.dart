library;

/// The Connect protocol this build speaks. 1: status, queue, commands, play-queue (no `protocol` field). 2: adds
/// `GET browse`, `GET art` and the `playItem` command, for controllers that browse the device's library (the watch).
const connectProtocolVersion = 2;

class ConnectDevice {
  const ConnectDevice({
    required this.name,
    required this.baseUrl,
    this.role = ConnectDevice.rolePlayer,
    this.id,
    this.startedAt,
  });

  /// A stable id of the install, from its mDNS TXT record (older devices send none). One device is one id, however
  /// many addresses or restarts it has gone through.
  final String? id;

  /// When the device's listener started (ms since epoch): of two records for the same device, the newer is the live one.
  final int? startedAt;

  /// What makes two entries the same device: the id, else name and role.
  String get identity => id != null && id!.isNotEmpty ? "id:$id" : "name:$name|$role";

  /// [devices] with each device once: where several entries share an identity (a restarted device's old record
  /// next to its new one, a device seen both by mDNS and by its own registration) the most recently started wins.
  static List<ConnectDevice> unique(Iterable<ConnectDevice> devices) {
    final byIdentity = <String, ConnectDevice>{};
    for (final device in devices) {
      final existing = byIdentity[device.identity];
      if (existing == null || (device.startedAt ?? 0) >= (existing.startedAt ?? 0)) {
        byIdentity[device.identity] = device;
      }
    }
    return byIdentity.values.toList();
  }

  final String name;

  final String baseUrl;

  /// What the device is, from its mDNS TXT record: [rolePlayer] (plays audio; older devices say nothing) or
  /// [roleWatch] (a remote only, never a playback target: it advertises itself only to receive accounts).
  final String role;

  static const rolePlayer = "player";
  static const roleWatch = "watch";

  bool get isWatch => role == roleWatch;

  Uri endpoint(String path, [Map<String, String>? query]) {
    final uri = Uri.parse("$baseUrl/$path");
    return query == null || query.isEmpty ? uri : uri.replace(queryParameters: query);
  }

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
    this.protocol = 1,
  });

  final ConnectSong? song;

  /// The device's [connectProtocolVersion]; 1 for devices that predate the field.
  final int protocol;

  /// The device can be browsed (`GET browse`), serves artwork (`GET art`) and takes `playItem`.
  bool get canBrowse => protocol >= 2;

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
    protocol: (json["protocol"] as num?)?.toInt() ?? 1,
  );

  Map<String, dynamic> toJson() => {
    "protocol": protocol,
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

  /// Indices into [items] in the order they play.
  List<int> get playOrder => shuffleOrder ?? List.generate(items.length, (i) => i);

  /// The `skipBy` offset that lands on [items]`[linearIndex]` from [from] (by default [index], the current track);
  /// null when either is not in the queue.
  int? offsetTo(int linearIndex, {int? from}) {
    final order = playOrder;
    final target = order.indexOf(linearIndex);
    final current = order.indexOf(from ?? index);
    if (target < 0 || current < 0) return null;
    return target - current;
  }

  /// [items]`[i]`'s title and artist, read from its `BaseItemDto` JSON.
  ({String title, String artist}) describe(int i) {
    final item = items[i];
    final artists = item["Artists"];
    return (
      title: (item["Name"] as String?) ?? "",
      artist:
          (item["AlbumArtist"] as String?) ??
          (artists is List && artists.isNotEmpty && artists.first is String ? artists.first as String : ""),
    );
  }

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
    final items = raw.whereType<Map<dynamic, dynamic>>().map((e) => e.cast<String, dynamic>()).toList();
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

/// What a controller can list from a device's library (`GET browse`, protocol 2).
enum ConnectBrowseView {
  albums,
  artists,
  playlists,

  /// Recently played tracks.
  recent,

  /// Favorite tracks.
  favorites,

  /// Artists, albums and tracks matching [ConnectBrowseRequest.query].
  search,

  /// What [ConnectBrowseRequest.parentId] holds: an artist's albums, an album's or a playlist's tracks.
  children;

  static ConnectBrowseView? tryParse(String? name) => values.where((v) => v.name == name).firstOrNull;
}

class ConnectBrowseRequest {
  const ConnectBrowseRequest(this.view, {this.parentId, this.query, this.start = 0, this.limit = defaultLimit});

  final ConnectBrowseView view;
  final String? parentId;
  final String? query;
  final int start;
  final int limit;

  static const defaultLimit = 50;
  static const maxLimit = 200;

  Map<String, String> toQuery() => {
    "view": view.name,
    "parent": ?parentId,
    "q": ?query,
    if (start != 0) "start": "$start",
    "limit": "$limit",
  };

  /// Null when the view is missing or unknown, or when a view that needs a parent or a query lacks it.
  static ConnectBrowseRequest? tryParse(Map<String, String> query) {
    final view = ConnectBrowseView.tryParse(query["view"]);
    if (view == null) return null;
    final parent = query["parent"];
    final q = query["q"]?.trim();
    if (view == ConnectBrowseView.children && (parent == null || parent.isEmpty)) return null;
    if (view == ConnectBrowseView.search && (q == null || q.isEmpty)) return null;
    return ConnectBrowseRequest(
      view,
      parentId: parent,
      query: q,
      start: (int.tryParse(query["start"] ?? "") ?? 0).clamp(0, 1 << 30),
      limit: (int.tryParse(query["limit"] ?? "") ?? defaultLimit).clamp(1, maxLimit),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ConnectBrowseRequest &&
      other.view == view &&
      other.parentId == parentId &&
      other.query == query &&
      other.start == start &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(view, parentId, query, start, limit);
}

/// One row of a browse listing: just enough to show it on a small screen and to ask the device to play it.
class ConnectBrowseItem {
  const ConnectBrowseItem({
    required this.id,
    required this.type,
    required this.title,
    this.subtitle = "",
    this.duration = 0,
    this.hasArt = false,
  });

  final String id;

  /// One of [track], [album], [artist], [playlist] or [other].
  final String type;

  final String title;
  final String subtitle;

  /// Seconds; 0 when unknown or not a track.
  final double duration;

  /// The device has artwork for it (fetch it with `GET art?id=`).
  final bool hasArt;

  static const track = "track";
  static const album = "album";
  static const artist = "artist";
  static const playlist = "playlist";
  static const other = "other";

  bool get isTrack => type == track;

  /// It holds other items that can be listed with [ConnectBrowseView.children].
  bool get isContainer => type == album || type == artist || type == playlist;

  static ConnectBrowseItem? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json["id"];
    if (id is! String || id.isEmpty) return null;
    return ConnectBrowseItem(
      id: id,
      type: (json["type"] as String?) ?? other,
      title: (json["title"] as String?) ?? "",
      subtitle: (json["subtitle"] as String?) ?? "",
      duration: ((json["duration"] ?? 0) as num).toDouble(),
      hasArt: json["art"] == true,
    );
  }

  /// The items of a `GET browse` answer (`{"items": [...]}`); malformed rows are dropped.
  static List<ConnectBrowseItem> listFrom(Object? json) {
    final raw = json is Map ? json["items"] : null;
    if (raw is! List) return const [];
    return raw.map(tryParse).nonNulls.toList();
  }

  Map<String, dynamic> toJson() => {
    "id": id,
    "type": type,
    "title": title,
    if (subtitle.isNotEmpty) "subtitle": subtitle,
    if (duration > 0) "duration": duration,
    if (hasArt) "art": true,
  };
}

/// How the `playItem` command (protocol 2) uses the item it names.
enum ConnectPlayMode {
  /// Replace the queue with it (from `startIndex` among its tracks) and play.
  play,

  /// Same, shuffled.
  shuffle,

  /// Insert it after the current track.
  next,

  /// Append it to the queue.
  queue;

  static ConnectPlayMode parse(Object? name) => values.where((v) => v.name == name).firstOrNull ?? play;
}
