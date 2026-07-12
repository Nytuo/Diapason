import 'package:isar/isar.dart';

part 'playback_event.g.dart';

@collection
class PlaybackEvent {
  PlaybackEvent({
    required this.trackId,
    required this.trackTitle,
    this.albumId,
    this.albumTitle,
    this.artistId,
    this.artistName = "",
    this.genre,
    required this.timestamp,
    required this.secondsListened,
    required this.trackSeconds,
    required this.wasCompleted,
    this.sourceId = "",
  });

  Id id = Isar.autoIncrement;

  @Index()
  String trackId;
  String trackTitle;

  String? albumId;
  String? albumTitle;
  String? artistId;
  String artistName;
  String? genre;

  @Index()
  DateTime timestamp;

  double secondsListened;
  double trackSeconds;

  bool wasCompleted;

  String sourceId;
}
