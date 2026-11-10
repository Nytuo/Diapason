import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/word_sync_parser.dart';

class LrcParser {
  /// One `[mm:ss]`, `[mm:ss.f]`, `[mm:ss.ff]` or `[mm:ss.fff]` timestamp. A line can start with several of them
  /// (`[00:12.00][00:45.00]Chorus`) when the same text is sung more than once.
  static final _timestamp = RegExp(r"\[(\d+):(\d+)(?:[.:](\d+))?\]");

  static LyricDto? parse(String content) {
    final enhanced = WordSyncParser.parseEnhancedLrc(content);
    if (enhanced != null) return enhanced;

    final timed = <(Duration, String)>[];

    for (final raw in content.split("\n")) {
      var rest = raw.trim();
      final starts = <Duration>[];
      while (true) {
        final match = _timestamp.matchAsPrefix(rest);
        if (match == null) break;
        starts.add(
          Duration(
            minutes: int.parse(match.group(1)!),
            seconds: int.parse(match.group(2)!),
            milliseconds: _fractionToMillis(match.group(3)),
          ),
        );
        rest = rest.substring(match.end);
      }
      if (starts.isEmpty) continue; // metadata tags like [ar:...] or untimed text
      final text = rest.trim();
      for (final start in starts) {
        timed.add((start, text));
      }
    }

    if (timed.isEmpty) return null;
    // Lines with several timestamps put later lines out of order; the player expects them sorted.
    timed.sort((a, b) => a.$1.compareTo(b.$1));
    return LyricDto(
      lyrics: [for (final (start, text) in timed) LyricLine(text: text, start: start.inMicroseconds * 10)],
    );
  }

  /// `.5` is half a second, `.05` five hundredths, `.005` five thousandths; extra digits are dropped.
  static int _fractionToMillis(String? fraction) {
    if (fraction == null || fraction.isEmpty) return 0;
    final digits = fraction.length >= 3 ? fraction.substring(0, 3) : fraction.padRight(3, "0");
    return int.parse(digits);
  }

  static LyricDto? plain(String content) {
    final lines = content.split("\n").where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return null;
    return LyricDto(lyrics: lines.map((text) => LyricLine(text: text)).toList());
  }

  static bool isSynced(LyricDto? lyrics) => lyrics?.lyrics?.any((line) => line.start != null) ?? false;
}
