import 'package:diapason/models/jellyfin_models.dart';

class LrcParser {
  static final _line = RegExp(r"\[(\d+):(\d+)(?:[.:](\d+))?\](.*)");

  static LyricDto? parse(String content) {
    final lines = <LyricLine>[];

    for (final raw in content.split("\n")) {
      final match = _line.firstMatch(raw.trim());
      if (match == null) continue;

      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = match.group(3);
      final millis = fraction == null ? 0 : (fraction.length == 2 ? int.parse(fraction) * 10 : int.parse(fraction));

      final start = Duration(minutes: minutes, seconds: seconds, milliseconds: millis);
      lines.add(LyricLine(text: match.group(4)!.trim(), start: start.inMicroseconds * 10));
    }

    return lines.isEmpty ? null : LyricDto(lyrics: lines);
  }

  static LyricDto? plain(String content) {
    final lines = content.split("\n").where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return null;
    return LyricDto(lyrics: lines.map((text) => LyricLine(text: text)).toList());
  }

  static bool isSynced(LyricDto? lyrics) =>
      lyrics?.lyrics?.any((line) => line.start != null) ?? false;
}
