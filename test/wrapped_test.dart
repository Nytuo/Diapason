import 'package:diapason/models/playback_event.dart';
import 'package:diapason/services/stats/stats_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("WrappedPeriod ranges", () {
    test("this month covers the calendar month", () {
      final range = WrappedPeriod.thisMonth.range(DateTime(2026, 7, 12));

      expect(range.start, DateTime(2026, 7, 1));
      expect(range.end, DateTime(2026, 8, 1));
    });

    test("last month in January is December of the year before", () {
      // The case a naive `month - 1` gets wrong.
      final range = WrappedPeriod.lastMonth.range(DateTime(2026, 1, 15));

      expect(range.start, DateTime(2025, 12, 1));
      expect(range.end, DateTime(2026, 1, 1));
    });

    test("this month in December rolls the year, not the month", () {
      final range = WrappedPeriod.thisMonth.range(DateTime(2026, 12, 5));

      expect(range.start, DateTime(2026, 12, 1));
      expect(range.end, DateTime(2027, 1, 1));
    });

    test("this year covers the calendar year", () {
      final range = WrappedPeriod.thisYear.range(DateTime(2026, 7, 12));

      expect(range.start, DateTime(2026, 1, 1));
      expect(range.end, DateTime(2027, 1, 1));
    });
  });

  group("listening streak", () {
    PlaybackEvent on(DateTime day) => PlaybackEvent(
      trackId: "t",
      trackTitle: "T",
      timestamp: day,
      secondsListened: 200,
      trackSeconds: 200,
      wasCompleted: true,
    );

    test("counts the longest run of consecutive days", () {
      final streak = StatsService.longestStreak([
        on(DateTime(2026, 3, 1)),
        on(DateTime(2026, 3, 2)),
        on(DateTime(2026, 3, 3)),
        // Gap.
        on(DateTime(2026, 3, 8)),
        on(DateTime(2026, 3, 9)),
      ]);

      expect(streak, 3);
    });

    test("several listens on one day are still one day", () {
      final streak = StatsService.longestStreak([
        on(DateTime(2026, 3, 1, 9)),
        on(DateTime(2026, 3, 1, 18)),
        on(DateTime(2026, 3, 1, 23)),
      ]);

      expect(streak, 1);
    });

    test("a daylight-saving change does not break a streak", () {
      // Clocks went forward on 29 March 2026 in Europe: that day is 23 hours
      // long, so a naive `difference.inDays == 1` check would drop the streak.
      final streak = StatsService.longestStreak([
        on(DateTime(2026, 3, 28)),
        on(DateTime(2026, 3, 29)),
        on(DateTime(2026, 3, 30)),
      ]);

      expect(streak, 3);
    });

    test("listens out of order still form a streak", () {
      final streak = StatsService.longestStreak([
        on(DateTime(2026, 3, 3)),
        on(DateTime(2026, 3, 1)),
        on(DateTime(2026, 3, 2)),
      ]);

      expect(streak, 3);
    });

    test("no listens is no streak", () {
      expect(StatsService.longestStreak([]), 0);
    });
  });

  group("empty Wrapped", () {
    test("reports itself as empty rather than pretending", () {
      final data = WrappedData.empty(WrappedPeriod.thisYear);

      expect(data.isEmpty, isTrue);
      expect(data.totalPlays, 0);
      expect(data.topTracks, isEmpty);
      expect(data.dominantGenre, isNull);
    });
  });
}
