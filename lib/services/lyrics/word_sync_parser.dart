import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:xml/xml.dart';
import 'package:yaml/yaml.dart';

/// Builds [LyricLine]s with word cues (the shape Jellyfin 10.10 sends) out of the word-by-word formats other lyric
/// databases use.
class WordSyncParser {
  static int _ticks(Duration d) => d.inMicroseconds * 10;

  /// One word (or syllable) of a line and when it is sung.
  static LyricLine _line(List<({String text, Duration start, Duration? end})> words, {Duration? lineStart}) {
    final buffer = StringBuffer();
    final cues = <LyricLineCue>[];
    for (final word in words) {
      final position = buffer.length;
      buffer.write(word.text);
      // Trailing whitespace belongs to the gap after a word, not to the word itself.
      final endPosition = position + word.text.trimRight().length;
      if (endPosition > position) {
        cues.add(
          LyricLineCue(
            position: position,
            endPosition: endPosition,
            start: _ticks(word.start),
            end: word.end == null ? null : _ticks(word.end!),
          ),
        );
      }
    }
    final text = buffer.toString().trimRight();
    final start = lineStart ?? (words.isEmpty ? null : words.first.start);
    return LyricLine(text: text, start: start == null ? null : _ticks(start), cues: cues.isEmpty ? null : cues);
  }

  static bool hasWordCues(LyricDto? lyrics) => lyrics?.lyrics?.any((line) => line.cues?.isNotEmpty ?? false) ?? false;

  // ---------------------------------------------------------------------------
  // TTML (Apple Music style, as stored in the AMLL TTML database)
  // ---------------------------------------------------------------------------

  /// Parses `1:02.345`, `00:01:02.345`, `62.345` or `62.345s`.
  static Duration? parseTtmlTime(String? raw) {
    if (raw == null) return null;
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.endsWith("ms")) {
      final ms = double.tryParse(value.substring(0, value.length - 2));
      return ms == null ? null : Duration(microseconds: (ms * 1000).round());
    }
    if (value.endsWith("s")) value = value.substring(0, value.length - 1);

    final parts = value.split(":");
    double seconds = 0;
    for (final part in parts) {
      final n = double.tryParse(part);
      if (n == null) return null;
      seconds = seconds * 60 + n;
    }
    return Duration(microseconds: (seconds * 1000000).round());
  }

  static String? _attr(XmlElement element, String local) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == local) return attribute.value;
    }
    return null;
  }

  /// Background vocals, translations and romanisations ride along as spans with a role; the karaoke line only wants
  /// the main vocal.
  static bool _isSideSpan(XmlElement element) {
    final role = _attr(element, "role");
    return role != null && role.startsWith("x-");
  }

  static LyricDto? parseTtml(String content) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(content);
    } catch (_) {
      return null;
    }

    final lines = <LyricLine>[];
    for (final p in document.descendants.whereType<XmlElement>().where((e) => e.name.local == "p")) {
      final lineStart = parseTtmlTime(_attr(p, "begin"));
      final words = <({String text, Duration start, Duration? end})>[];
      final timed = p.childElements.any((e) => e.name.local == "span" && _attr(e, "begin") != null);

      if (!timed) {
        final text = p.innerText.trim();
        if (text.isNotEmpty) {
          lines.add(LyricLine(text: text, start: lineStart == null ? null : _ticks(lineStart)));
        }
        continue;
      }

      for (final node in p.children) {
        if (node is XmlText) {
          // Spaces between word spans: attach them to the previous word so cue positions stay right.
          if (words.isNotEmpty && node.value.isNotEmpty) {
            final last = words.removeLast();
            words.add((text: last.text + node.value.replaceAll(RegExp(r"\s+"), " "), start: last.start, end: last.end));
          }
          continue;
        }
        if (node is! XmlElement || node.name.local != "span" || _isSideSpan(node)) continue;

        final start = parseTtmlTime(_attr(node, "begin"));
        final text = node.innerText;
        if (start == null || text.isEmpty) continue;
        words.add((text: text, start: start, end: parseTtmlTime(_attr(node, "end"))));
      }

      if (words.isNotEmpty) lines.add(_line(words, lineStart: lineStart));
    }

    return lines.isEmpty ? null : LyricDto(lyrics: lines);
  }

  // ---------------------------------------------------------------------------
  // Enhanced LRC (A2 extension): [00:12.00]<00:12.00>Word <00:12.50>by <00:12.80>word
  // ---------------------------------------------------------------------------

  static final _lrcLine = RegExp(r"^\[(\d+):(\d+)(?:[.:](\d+))?\](.*)$");
  static final _wordTag = RegExp(r"<(\d+):(\d+)(?:[.:](\d+))?>");

  static Duration _lrcTime(String minutes, String seconds, String? fraction) {
    final millis = fraction == null
        ? 0
        : switch (fraction.length) {
            1 => int.parse(fraction) * 100,
            2 => int.parse(fraction) * 10,
            _ => int.parse(fraction.substring(0, 3)),
          };
    return Duration(minutes: int.parse(minutes), seconds: int.parse(seconds), milliseconds: millis);
  }

  /// Null unless at least one line carries inline word timestamps.
  static LyricDto? parseEnhancedLrc(String content) {
    if (!_wordTag.hasMatch(content)) return null;

    final lines = <LyricLine>[];
    for (final raw in content.split("\n")) {
      final match = _lrcLine.firstMatch(raw.trim());
      if (match == null) continue;
      final lineStart = _lrcTime(match.group(1)!, match.group(2)!, match.group(3));
      final body = match.group(4)!;

      final tags = _wordTag.allMatches(body).toList();
      if (tags.isEmpty) {
        lines.add(LyricLine(text: body.trim(), start: _ticks(lineStart)));
        continue;
      }

      final words = <({String text, Duration start, Duration? end})>[];
      final leading = body.substring(0, tags.first.start);
      for (var i = 0; i < tags.length; i++) {
        final tag = tags[i];
        final textEnd = i + 1 < tags.length ? tags[i + 1].start : body.length;
        var text = body.substring(tag.end, textEnd);
        if (i == 0) text = leading.trimLeft() + text;
        final start = _lrcTime(tag.group(1)!, tag.group(2)!, tag.group(3));
        // A tag with no text after it only marks where the previous word ends.
        if (text.trim().isEmpty) {
          if (words.isNotEmpty) {
            final last = words.removeLast();
            words.add((text: last.text + text, start: last.start, end: start));
          }
          continue;
        }
        words.add((text: text, start: start, end: null));
      }
      lines.add(_line(words, lineStart: lineStart));
    }

    return lines.isEmpty ? null : LyricDto(lyrics: lines);
  }

  // ---------------------------------------------------------------------------
  // NetEase YRC: [33520,2520](33520,420,0)Look (33940,270,0)at
  // ---------------------------------------------------------------------------

  static final _yrcLine = RegExp(r"^\[(\d+),(\d+)\](.*)$");
  static final _yrcWord = RegExp(r"\((\d+),(\d+),\d+\)([^(]*)");

  static LyricDto? parseYrc(String content) {
    final lines = <LyricLine>[];
    for (final raw in content.split("\n")) {
      final match = _yrcLine.firstMatch(raw.trim());
      if (match == null) continue; // JSON credit lines start with "{"
      final lineStart = Duration(milliseconds: int.parse(match.group(1)!));
      final words = <({String text, Duration start, Duration? end})>[
        for (final word in _yrcWord.allMatches(match.group(3)!))
          if (word.group(3)!.isNotEmpty)
            (
              text: word.group(3)!,
              start: Duration(milliseconds: int.parse(word.group(1)!)),
              end: Duration(milliseconds: int.parse(word.group(1)!) + int.parse(word.group(2)!)),
            ),
      ];
      if (words.isNotEmpty) lines.add(_line(words, lineStart: lineStart));
    }
    return lines.isEmpty ? null : LyricDto(lyrics: lines);
  }

  // ---------------------------------------------------------------------------
  // Lyricsfile 1.0 (LRCLIB's YAML format): https://github.com/tranxuanthang/lyricsfile
  // ---------------------------------------------------------------------------

  /// Word-synced, line-synced or plain lyrics from a Lyricsfile, whichever it holds. Null for instrumentals, other
  /// versions (the spec says not to read those as 1.0) and malformed files.
  static LyricDto? parseLyricsfile(String content) {
    final Object? doc;
    try {
      doc = loadYaml(content);
    } catch (_) {
      return null;
    }
    if (doc is! YamlMap || "${doc["version"]}" != "1.0") return null;
    final metadata = doc["metadata"];
    if (metadata is YamlMap && metadata["instrumental"] == true) return null;

    Duration? ms(Object? v) => v is int && v >= 0 ? Duration(milliseconds: v) : null;

    final lines = <LyricLine>[];
    final rawLines = doc["lines"];
    if (rawLines is YamlList) {
      for (final raw in rawLines.whereType<YamlMap>()) {
        final text = raw["text"];
        final start = ms(raw["start_ms"]);
        if (text is! String || start == null) continue;
        final rawWords = raw["words"];
        final words = <({String text, Duration start, Duration? end})>[
          if (rawWords is YamlList)
            for (final w in rawWords.whereType<YamlMap>())
              if (w["text"] is String && ms(w["start_ms"]) != null)
                (text: w["text"] as String, start: ms(w["start_ms"])!, end: ms(w["end_ms"])),
        ];
        if (words.isEmpty) {
          lines.add(LyricLine(text: text.trim(), start: _ticks(start)));
        } else {
          final line = _line(words, lineStart: start);
          // A word without its own end lasts until the next one, or the end of the line.
          final lineEnd = ms(raw["end_ms"]);
          final cues = line.cues;
          if (lineEnd != null && cues != null && cues.isNotEmpty && cues.last.end == null) {
            cues.last.end = _ticks(lineEnd);
          }
          lines.add(line);
        }
      }
    }
    if (lines.isNotEmpty) return LyricDto(lyrics: lines);

    final plain = doc["plain"];
    return plain is String && plain.trim().isNotEmpty ? LrcParser.plain(plain) : null;
  }
}
