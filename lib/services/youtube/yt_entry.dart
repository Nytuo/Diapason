/// A YouTube video as listed by yt-dlp (locally or via the uploader).
class YtEntry {
  const YtEntry({required this.id, required this.title, required this.artist, required this.durationSecs});

  factory YtEntry.fromJson(Map<String, dynamic> json) => YtEntry(
    id: json["id"] as String,
    title: (json["title"] as String?) ?? "",
    artist: (json["artist"] as String?) ?? "",
    durationSecs: (json["durationSecs"] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String title;
  final String artist;
  final int durationSecs;
}
