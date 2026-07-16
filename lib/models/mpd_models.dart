class MpdStatus {
  MpdStatus({
    required this.state,
    required this.volume,
    required this.elapsed,
    required this.duration,
    required this.songId,
    required this.repeat,
    required this.random,
    this.song,
  });

  final String state;
  final int volume;
  final Duration elapsed;
  final Duration duration;
  final int? songId;
  final bool repeat;
  final bool random;
  final MpdSong? song;

  bool get isPlaying => state == "play";

  static MpdStatus empty() =>
      MpdStatus(state: "stop", volume: -1, elapsed: Duration.zero, duration: Duration.zero, songId: null, repeat: false, random: false);
}

class MpdSong {
  MpdSong({required this.file, this.title, this.artist, this.album, this.duration, this.id, this.pos});

  final String file;
  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;

  final int? id;
  final int? pos;

  String get displayTitle => title ?? file.split("/").last;

  factory MpdSong.fromMap(Map<String, String> m) {
    Duration? dur;
    final time = m["duration"] ?? m["Time"];
    if (time != null) {
      final secs = double.tryParse(time);
      if (secs != null) dur = Duration(milliseconds: (secs * 1000).round());
    }
    return MpdSong(
      file: m["file"] ?? "",
      title: m["Title"],
      artist: m["Artist"] ?? m["AlbumArtist"],
      album: m["Album"],
      duration: dur,
      id: int.tryParse(m["Id"] ?? ""),
      pos: int.tryParse(m["Pos"] ?? ""),
    );
  }
}

enum MpdEntryKind { directory, file, playlist }

class MpdEntry {
  MpdEntry({required this.kind, required this.path, this.song});

  final MpdEntryKind kind;
  final String path;
  final MpdSong? song;

  String get name => path.split("/").last;
}
