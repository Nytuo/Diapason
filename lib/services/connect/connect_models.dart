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
  const ConnectStatus({this.song, required this.state, required this.position, required this.volume});

  final ConnectSong? song;

  final String state;

  final double position;
  final double volume;

  bool get isPlaying => state == "playing";

  static const stopped = ConnectStatus(song: null, state: "stopped", position: 0, volume: 1);

  factory ConnectStatus.fromJson(Map<String, dynamic> json) => ConnectStatus(
    song: json["song"] == null ? null : ConnectSong.fromJson(json["song"] as Map<String, dynamic>),
    state: (json["state"] ?? "stopped") as String,
    position: ((json["position"] ?? 0) as num).toDouble(),
    volume: ((json["volume"] ?? 1) as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    "song": song?.toJson(),
    "state": state,
    "position": position,
    "volume": volume,
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
  const ConnectCommand(this.action, {this.position, this.volume});

  final String action;
  final double? position;
  final double? volume;

  factory ConnectCommand.fromJson(Map<String, dynamic> json) => ConnectCommand(
    (json["action"] ?? "") as String,
    position: (json["position"] as num?)?.toDouble(),
    volume: (json["volume"] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    "action": action,
    if (position != null) "position": position,
    if (volume != null) "volume": volume,
  };
}
