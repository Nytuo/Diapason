import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/playback_event.dart';
import 'package:diapason/services/scrobbling/scrobble_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';

enum WrappedPeriod {
  thisMonth,
  lastMonth,
  thisYear;

  String get displayName => switch (this) {
    WrappedPeriod.thisMonth => "This month",
    WrappedPeriod.lastMonth => "Last month",
    WrappedPeriod.thisYear => "This year",
  };

  ({DateTime start, DateTime end}) range([DateTime? now]) {
    final today = now ?? DateTime.now();
    return switch (this) {
      WrappedPeriod.thisMonth => (
        start: DateTime(today.year, today.month),
        end: DateTime(today.year, today.month + 1),
      ),
      WrappedPeriod.lastMonth => (
        start: DateTime(today.year, today.month - 1),
        end: DateTime(today.year, today.month),
      ),
      WrappedPeriod.thisYear => (start: DateTime(today.year), end: DateTime(today.year + 1)),
    };
  }
}

class WrappedEntry {
  const WrappedEntry({required this.name, required this.subtitle, required this.plays});

  final String name;
  final String subtitle;
  final int plays;
}

class WrappedData {
  const WrappedData({
    required this.period,
    required this.totalPlays,
    required this.minutesListened,
    required this.topTracks,
    required this.topAlbums,
    required this.topArtists,
    required this.dominantGenre,
    required this.streakDays,
    required this.distinctArtists,
  });

  final WrappedPeriod period;
  final int totalPlays;
  final int minutesListened;
  final List<WrappedEntry> topTracks;
  final List<WrappedEntry> topAlbums;
  final List<WrappedEntry> topArtists;
  final String? dominantGenre;

  final int streakDays;

  final int distinctArtists;

  bool get isEmpty => totalPlays == 0;

  static WrappedData empty(WrappedPeriod period) => WrappedData(
    period: period,
    totalPlays: 0,
    minutesListened: 0,
    topTracks: const [],
    topAlbums: const [],
    topArtists: const [],
    dominantGenre: null,
    streakDays: 0,
    distinctArtists: 0,
  );
}

class StatsService {
  StatsService();

  static final _log = Logger("StatsService");

  Isar get _isar => GetIt.instance<Isar>();

  Future<void> record(BaseItemDto item, {required Duration played, DateTime? startedAt}) async {
    if (played < const Duration(seconds: 5)) return;

    final duration = item.runTimeTicksDuration();
    final event = PlaybackEvent(
      trackId: item.id.raw,
      trackTitle: item.name ?? "Unknown",
      albumId: item.albumId?.raw,
      albumTitle: item.album,
      artistId: item.artistItems?.firstOrNull?.id.raw,
      artistName: item.albumArtist ?? item.artists?.firstOrNull ?? "Unknown Artist",
      genre: item.genres?.firstOrNull,
      timestamp: startedAt ?? DateTime.now().subtract(played),
      secondsListened: played.inMilliseconds / 1000,
      trackSeconds: (duration?.inMilliseconds ?? 0) / 1000,
      wasCompleted: ScrobbleService.qualifies(played, duration),
      sourceId: item.id.sourceId,
    );

    try {
      await _isar.writeTxn(() => _isar.playbackEvents.put(event));
    } catch (e) {
      _log.warning("Could not record a listen for '${item.name}': $e");
    }
  }

  Future<List<PlaybackEvent>> eventsIn(WrappedPeriod period, [DateTime? now]) async {
    final range = period.range(now);
    return _isar.playbackEvents
        .filter()
        .timestampGreaterThan(range.start, include: true)
        .timestampLessThan(range.end)
        .findAll();
  }

  Future<WrappedData> build(WrappedPeriod period, [DateTime? now]) async {
    final events = await eventsIn(period, now);
    final listens = events.where((e) => e.wasCompleted).toList();

    if (listens.isEmpty) return WrappedData.empty(period);

    final minutes = listens.fold<double>(0, (sum, e) => sum + e.secondsListened) ~/ 60;

    return WrappedData(
      period: period,
      totalPlays: listens.length,
      minutesListened: minutes,
      topTracks: _rank(
        listens,
        key: (e) => e.trackId,
        name: (e) => e.trackTitle,
        subtitle: (e) => e.artistName,
      ),
      topAlbums: _rank(
        listens.where((e) => (e.albumTitle ?? "").isNotEmpty),
        key: (e) => e.albumId ?? e.albumTitle!,
        name: (e) => e.albumTitle!,
        subtitle: (e) => e.artistName,
      ),
      topArtists: _rank(
        listens,
        key: (e) => e.artistName,
        name: (e) => e.artistName,
        subtitle: (e) => "",
      ),
      dominantGenre: _dominant(listens.map((e) => e.genre).nonNulls.where((g) => g.isNotEmpty)),
      streakDays: longestStreak(listens),
      distinctArtists: listens.map((e) => e.artistName).toSet().length,
    );
  }

  static List<WrappedEntry> _rank(
    Iterable<PlaybackEvent> events, {
    required String Function(PlaybackEvent) key,
    required String Function(PlaybackEvent) name,
    required String Function(PlaybackEvent) subtitle,
    int limit = 10,
  }) {
    final counts = <String, int>{};
    final examples = <String, PlaybackEvent>{};

    for (final event in events) {
      final k = key(event);
      counts[k] = (counts[k] ?? 0) + 1;
      examples[k] = event;
    }

    final ranked = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return ranked
        .take(limit)
        .map(
          (e) => WrappedEntry(
            name: name(examples[e.key]!),
            subtitle: subtitle(examples[e.key]!),
            plays: e.value,
          ),
        )
        .toList();
  }

  static String? _dominant(Iterable<String> values) {
    if (values.isEmpty) return null;
    final counts = <String, int>{};
    for (final value in values) {
      counts[value] = (counts[value] ?? 0) + 1;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  @visibleForTesting
  static int longestStreak(List<PlaybackEvent> events) {
    if (events.isEmpty) return 0;

    final days =
        events.map((e) => DateTime(e.timestamp.year, e.timestamp.month, e.timestamp.day)).toSet().toList()
          ..sort();

    var longest = 1;
    var current = 1;
    for (var i = 1; i < days.length; i++) {
      final gap = days[i].difference(days[i - 1]).inHours;
      if (gap > 20 && gap < 28) {
        current++;
        longest = current > longest ? current : longest;
      } else {
        current = 1;
      }
    }
    return longest;
  }

  Future<void> clear() async {
    await _isar.writeTxn(() => _isar.playbackEvents.clear());
    _log.info("Cleared the listening history");
  }
}
