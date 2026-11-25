import 'dart:math';

import 'package:diapason/models/jellyfin_models.dart';

enum LyricsExportFormat {
  lrc("lrc", "application/x-lrc"),
  enhancedLrc("lrc", "application/x-lrc"),
  srt("srt", "application/x-subrip"),
  txt("txt", "text/plain");

  const LyricsExportFormat(this.extension, this.mimeType);

  final String extension;
  final String mimeType;

  /// LRC and SRT need line timings; enhanced LRC needs word timings too.
  bool availableFor(List<LyricLine> lines) => switch (this) {
    LyricsExportFormat.txt => true,
    LyricsExportFormat.lrc || LyricsExportFormat.srt => lines.any((l) => l.start != null),
    LyricsExportFormat.enhancedLrc => lines.any((l) => l.cues?.isNotEmpty ?? false),
  };
}

/// What the exported file says the lyrics belong to.
class LyricsExportMetadata {
  const LyricsExportMetadata({this.title, this.artist, this.album, this.length});

  final String? title;
  final String? artist;
  final String? album;
  final Duration? length;
}

/// Writes lyrics as LRC (optionally word-timed "enhanced" LRC), SubRip or plain text.
///
/// [offsetMs] is the track's lyrics offset (positive: lyrics shown later); it is baked into the timings so the file
/// lines up with the audio in other players.
class LyricsExporter {
  LyricsExporter._();

  static String export(
    LyricsExportFormat format,
    List<LyricLine> lines, {
    LyricsExportMetadata metadata = const LyricsExportMetadata(),
    int offsetMs = 0,
  }) => switch (format) {
    LyricsExportFormat.lrc => toLrc(lines, metadata: metadata, offsetMs: offsetMs),
    LyricsExportFormat.enhancedLrc => toLrc(lines, metadata: metadata, offsetMs: offsetMs, wordTimings: true),
    LyricsExportFormat.srt => toSrt(lines, length: metadata.length, offsetMs: offsetMs),
    LyricsExportFormat.txt => toTxt(lines),
  };

  /// `title - artist.ext`, without characters file systems refuse.
  static String fileName(LyricsExportMetadata metadata, LyricsExportFormat format) {
    final base = [metadata.artist, metadata.title].whereType<String>().where((s) => s.trim().isNotEmpty).join(" - ");
    final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), "_").trim();
    return "${safe.isEmpty ? "lyrics" : safe}.${format.extension}";
  }

  static int _shifted(int micros, int offsetMs) => max(0, micros + offsetMs * 1000);

  /// `mm:ss.xx` (centiseconds, as most LRC readers expect).
  static String lrcTime(int micros) {
    final centis = (micros / 10000).round();
    final minutes = centis ~/ 6000;
    final seconds = (centis ~/ 100) % 60;
    final hundredths = centis % 100;
    return "${minutes.toString().padLeft(2, "0")}:${seconds.toString().padLeft(2, "0")}."
        "${hundredths.toString().padLeft(2, "0")}";
  }

  /// `HH:MM:SS,mmm`.
  static String srtTime(int micros) {
    final ms = (micros / 1000).round();
    final h = ms ~/ 3600000;
    final m = (ms ~/ 60000) % 60;
    final s = (ms ~/ 1000) % 60;
    final rest = ms % 1000;
    return "${h.toString().padLeft(2, "0")}:${m.toString().padLeft(2, "0")}:${s.toString().padLeft(2, "0")},"
        "${rest.toString().padLeft(3, "0")}";
  }

  static String _tagValue(String value) =>
      value.replaceAll(RegExp(r"[\[\]]"), "").replaceAll(RegExp(r"\s+"), " ").trim();

  static String toLrc(
    List<LyricLine> lines, {
    LyricsExportMetadata metadata = const LyricsExportMetadata(),
    int offsetMs = 0,
    bool wordTimings = false,
  }) {
    final out = StringBuffer();
    void tag(String name, String? value) {
      if (value != null && value.trim().isNotEmpty) out.writeln("[$name:${_tagValue(value)}]");
    }

    tag("ar", metadata.artist);
    tag("ti", metadata.title);
    tag("al", metadata.album);
    final length = metadata.length;
    if (length != null && length > Duration.zero) {
      tag(
        "length",
        "${length.inMinutes.toString().padLeft(2, "0")}:${(length.inSeconds % 60).toString().padLeft(2, "0")}",
      );
    }

    for (final line in lines) {
      if (line.start == null) continue;
      final text = (line.text ?? "").replaceAll(RegExp(r"[\r\n]+"), " ");
      out.write("[${lrcTime(_shifted(line.startMicros, offsetMs))}]");
      final cues = line.cues;
      if (!wordTimings || cues == null || cues.isEmpty) {
        out.writeln(text.trimRight());
        continue;
      }
      // A2 "enhanced LRC": <time> before each word, and a closing <time> when the last word's end is known.
      final first = cues.first.position.clamp(0, text.length);
      out.write(text.substring(0, first));
      for (var i = 0; i < cues.length; i++) {
        final cue = cues[i];
        final from = cue.position.clamp(0, text.length);
        final to = (i + 1 < cues.length ? cues[i + 1].position : text.length).clamp(from, text.length);
        out.write("<${lrcTime(_shifted(cue.startMicros, offsetMs))}>${text.substring(from, to)}");
      }
      final lastEnd = cues.last.endMicros;
      if (lastEnd != null) {
        out.write("<${lrcTime(_shifted(lastEnd, offsetMs))}>");
      }
      out.writeln();
    }
    return out.toString();
  }

  /// Each line lasts until the next one starts (or its last word ends, if earlier); the last one until the end of the
  /// track, or 5 s. Empty lines only mark where the previous one stops.
  static String toSrt(List<LyricLine> lines, {Duration? length, int offsetMs = 0}) {
    final timed = lines.where((l) => l.start != null).toList();
    final out = StringBuffer();
    var index = 1;
    for (var i = 0; i < timed.length; i++) {
      final line = timed[i];
      final text = (line.text ?? "").trim();
      if (text.isEmpty) continue;
      final start = line.startMicros;
      var end = i + 1 < timed.length
          ? timed[i + 1].startMicros
          : (length != null && length.inMicroseconds > start ? length.inMicroseconds : start + 5000000);
      final wordsEnd = line.cues?.lastOrNull?.endMicros;
      if (wordsEnd != null && wordsEnd > start && wordsEnd < end) end = wordsEnd;
      if (end <= start) end = start + 1000000;
      out
        ..writeln(index++)
        ..writeln("${srtTime(_shifted(start, offsetMs))} --> ${srtTime(_shifted(end, offsetMs))}")
        ..writeln(text)
        ..writeln();
    }
    return out.toString();
  }

  static String toTxt(List<LyricLine> lines) => "${lines.map((l) => (l.text ?? "").trimRight()).join("\n").trim()}\n";
}
