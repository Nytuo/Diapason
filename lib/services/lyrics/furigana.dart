import 'package:kana_kit/kana_kit.dart';

/// A reading shown above part of a lyric line: [reading] (hiragana) over the characters `[start, end)`.
///
/// Positions are UTF-16 offsets into the line's text, the same ones word cues use, so the karaoke fill and the
/// readings line up.
class RubySegment {
  const RubySegment(this.start, this.end, this.reading);

  final int start;
  final int end;
  final String reading;

  @override
  bool operator ==(Object other) =>
      other is RubySegment && other.start == start && other.end == end && other.reading == reading;

  @override
  int get hashCode => Object.hash(start, end, reading);

  @override
  String toString() => "RubySegment($start, $end, $reading)";

  List<Object> toWire() => [start, end, reading];

  static RubySegment fromWire(List<Object?> wire) => RubySegment(wire[0]! as int, wire[1]! as int, wire[2]! as String);
}

/// What a tokenizer says about one word: how it is written and how it is read (in katakana, as IPADIC gives it).
class JapaneseToken {
  const JapaneseToken({required this.surface, this.reading, this.pos});

  final String surface;

  /// Katakana reading, or null for unknown words (latin text, numbers, rare names).
  final String? reading;

  /// Part of speech (`名詞`, `助詞`…), used for particles in romaji.
  final String? pos;
}

/// Readings and romaji for one line.
class FuriganaLine {
  const FuriganaLine({this.ruby = const [], this.romaji});

  final List<RubySegment> ruby;

  /// Hepburn romaji of the whole line, or null when the line has no Japanese.
  final String? romaji;

  static const empty = FuriganaLine();

  bool get isEmpty => ruby.isEmpty && romaji == null;

  List<Object?> toWire() => [romaji, for (final r in ruby) r.toWire()];

  static FuriganaLine fromWire(List<Object?> wire) => FuriganaLine(
    romaji: wire[0] as String?,
    ruby: [for (final r in wire.skip(1)) RubySegment.fromWire(r! as List<Object?>)],
  );
}

/// Script checks and the alignment of a word's reading over its kanji. Pure functions, so they're tested without the
/// dictionary.
class Furigana {
  Furigana._();

  static const _kana = KanaKit();

  static bool isKanjiCode(int c) =>
      (c >= 0x4E00 && c <= 0x9FFF) || // CJK unified ideographs
      (c >= 0x3400 && c <= 0x4DBF) || // extension A
      (c >= 0xF900 && c <= 0xFAFF) || // compatibility ideographs
      c == 0x3005 || // 々
      c == 0x3006 || // 〆
      c == 0x30F6; // ヶ (as in 一ヶ月)

  static bool isKanaCode(int c) => (c >= 0x3041 && c <= 0x309F) || (c >= 0x30A0 && c <= 0x30FF && c != 0x30F6);

  static bool hasKanji(String text) => text.codeUnits.any(isKanjiCode);

  static bool hasKana(String text) => text.codeUnits.any(isKanaCode);

  static bool hasJapanese(String text) => text.codeUnits.any((c) => isKanjiCode(c) || isKanaCode(c));

  /// Kanji is shared with Chinese: a song counts as Japanese when some of its lines have kana. Then even a line in
  /// kanji only (「東京」) gets readings, and Chinese lyrics never do.
  static bool isJapaneseSong(Iterable<String?> lines) => lines.any((l) => l != null && hasKana(l));

  /// Katakana to hiragana; everything else is kept (ー stays, so long vowels survive).
  static String toHiragana(String text) {
    final out = StringBuffer();
    for (final c in text.codeUnits) {
      // ァ..ヶ map onto ぁ..ゖ; ヷ-ヺ, ・, ー have no hiragana.
      out.writeCharCode(c >= 0x30A1 && c <= 0x30F6 ? c - 0x60 : c);
    }
    return out.toString();
  }

  /// Readings over the kanji of one word starting at [offset] in its line. Kana around the kanji (okurigana) is
  /// matched against the reading and gets no ruby: in 食べた (タベタ) only 食 is annotated, with "た". When the kana
  /// can't be anchored, the whole word gets the reading.
  static List<RubySegment> alignToken(String surface, String? reading, int offset) {
    if (reading == null || reading.isEmpty || reading == "*" || !hasKanji(surface)) return const [];
    final read = toHiragana(reading);
    if (read == toHiragana(surface)) return const [];

    // Runs of kanji and of everything else, with where they start in the surface.
    final runs = <({String text, int start, bool kanji})>[];
    for (var i = 0; i < surface.length;) {
      final kanji = isKanjiCode(surface.codeUnitAt(i));
      var j = i + 1;
      while (j < surface.length && isKanjiCode(surface.codeUnitAt(j)) == kanji) {
        j++;
      }
      runs.add((text: surface.substring(i, j), start: i, kanji: kanji));
      i = j;
    }

    final pattern = StringBuffer("^");
    for (final run in runs) {
      pattern.write(run.kanji ? "(.+?)" : RegExp.escape(toHiragana(run.text)));
    }
    pattern.write(r"$");
    final match = RegExp(pattern.toString()).firstMatch(read);
    if (match == null) {
      return [RubySegment(offset, offset + surface.length, read)];
    }

    final out = <RubySegment>[];
    var group = 1;
    for (final run in runs) {
      if (!run.kanji) continue;
      final text = match.group(group++)!;
      if (text != run.text) out.add(RubySegment(offset + run.start, offset + run.start + run.text.length, text));
    }
    return out;
  }

  /// Readings for a whole line, from its tokens. Null when the tokens don't spell the line exactly (then nothing is
  /// annotated rather than something misplaced).
  static List<RubySegment>? rubyForTokens(String line, List<JapaneseToken> tokens) {
    final out = <RubySegment>[];
    var offset = 0;
    for (final token in tokens) {
      if (!line.startsWith(token.surface, offset)) return null;
      out.addAll(alignToken(token.surface, token.reading, offset));
      offset += token.surface.length;
    }
    return offset == line.length ? out : null;
  }

  /// Hepburn romaji, one word per token, particles read the way they're pronounced (は → wa, へ → e, を → o).
  static String? romajiForTokens(List<JapaneseToken> tokens) {
    if (!tokens.any((t) => hasJapanese(t.surface))) return null;
    final words = <String>[];
    for (final token in tokens) {
      final surface = token.surface;
      if (surface.trim().isEmpty) continue;
      String word;
      if (token.pos == "助詞" && (surface == "は" || surface == "へ" || surface == "を")) {
        word = switch (surface) {
          "は" => "wa",
          "へ" => "e",
          _ => "o",
        };
      } else if (hasJapanese(surface)) {
        final reading = token.reading != null && token.reading != "*" ? token.reading! : surface;
        word = _kana.toRomaji(toHiragana(reading));
      } else {
        word = surface;
      }
      // Punctuation and small endings stick to the word before them.
      final isPunctuation = !RegExp(r"[\p{L}\p{N}]", unicode: true).hasMatch(word);
      if (words.isNotEmpty && isPunctuation) {
        words[words.length - 1] = words.last + word;
      } else {
        words.add(word);
      }
    }
    final text = words.join(" ").trim();
    return text.isEmpty ? null : text;
  }
}
