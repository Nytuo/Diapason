import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:diapason/services/lyrics/furigana.dart';
import 'package:diapason/services/lyrics/japanese_dictionary.dart';
import 'package:flutter_test/flutter_test.dart';
// The package embeds the same gzipped IPADIC parts the app downloads; tests write them to disk instead of fetching.
// ignore_for_file: implementation_imports
import 'package:kuromoji/src/dict/data/base.dat.dart';
import 'package:kuromoji/src/dict/data/cc.dat.dart';
import 'package:kuromoji/src/dict/data/check.dat.dart';
import 'package:kuromoji/src/dict/data/tid.dat.dart';
import 'package:kuromoji/src/dict/data/tid_map.dat.dart';
import 'package:kuromoji/src/dict/data/tid_pos.dat.dart';
import 'package:kuromoji/src/dict/data/unk.dat.dart';
import 'package:kuromoji/src/dict/data/unk_char.dat.dart';
import 'package:kuromoji/src/dict/data/unk_compat.dat.dart';
import 'package:kuromoji/src/dict/data/unk_invoke.dat.dart';
import 'package:kuromoji/src/dict/data/unk_map.dat.dart';
import 'package:kuromoji/src/dict/data/unk_pos.dat.dart';

Map<String, Uint8List> get _embedded => {
  "base.dat.gz": baseData,
  "cc.dat.gz": ccData,
  "check.dat.gz": checkData,
  "tid.dat.gz": tidData,
  "tid_map.dat.gz": tid_mapData,
  "tid_pos.dat.gz": tid_posData,
  "unk.dat.gz": unkData,
  "unk_char.dat.gz": unk_charData,
  "unk_compat.dat.gz": unk_compatData,
  "unk_invoke.dat.gz": unk_invokeData,
  "unk_map.dat.gz": unk_mapData,
  "unk_pos.dat.gz": unk_posData,
};

void main() {
  group("alignToken", () {
    test("kana-only and latin words get nothing", () {
      expect(Furigana.alignToken("ありがとう", "アリガトウ", 0), isEmpty);
      expect(Furigana.alignToken("love", null, 0), isEmpty);
    });

    test("okurigana stays bare", () {
      expect(Furigana.alignToken("食べた", "タベタ", 3), [const RubySegment(3, 4, "た")]);
      expect(Furigana.alignToken("歩いて", "アルイテ", 0), [const RubySegment(0, 1, "ある")]);
    });

    test("compound words get one reading", () {
      expect(Furigana.alignToken("夜空", "ヨゾラ", 0), [const RubySegment(0, 2, "よぞら")]);
    });

    test("kana between kanji anchors both sides", () {
      expect(Furigana.alignToken("思い出", "オモイデ", 0), [const RubySegment(0, 1, "おも"), const RubySegment(2, 3, "で")]);
    });

    test("unanchorable reading covers the whole word", () {
      // The surface's kana doesn't appear in the reading.
      expect(Furigana.alignToken("今日は", "キョウワ", 0), [const RubySegment(0, 3, "きょうわ")]);
    });

    test("unknown words without reading are left alone", () {
      expect(Furigana.alignToken("漢", "*", 0), isEmpty);
    });
  });

  test("rubyForTokens refuses tokens that don't spell the line", () {
    expect(Furigana.rubyForTokens("君の名", const [JapaneseToken(surface: "君", reading: "キミ")]), isNull);
    expect(
      Furigana.rubyForTokens("君の名", const [
        JapaneseToken(surface: "君", reading: "キミ"),
        JapaneseToken(surface: "の", reading: "ノ", pos: "助詞"),
        JapaneseToken(surface: "名", reading: "ナ"),
      ]),
      [const RubySegment(0, 1, "きみ"), const RubySegment(2, 3, "な")],
    );
  });

  test("romaji reads particles as pronounced", () {
    final romaji = Furigana.romajiForTokens(const [
      JapaneseToken(surface: "私", reading: "ワタシ", pos: "名詞"),
      JapaneseToken(surface: "は", reading: "ハ", pos: "助詞"),
      JapaneseToken(surface: "猫", reading: "ネコ", pos: "名詞"),
      JapaneseToken(surface: "、", pos: "記号"),
    ]);
    expect(romaji, "watashi wa neko、");
    expect(Furigana.romajiForTokens(const [JapaneseToken(surface: "hello")]), isNull);
  });

  test("script detection", () {
    expect(Furigana.isJapaneseSong(["東京", "君がいた"]), isTrue);
    expect(Furigana.isJapaneseSong(["我爱你", "月亮代表我的心"]), isFalse);
    expect(Furigana.toHiragana("カタカナー"), "かたかなー");
  });

  group("with the IPADIC dictionary", () {
    late final Directory dir;
    late final tokenizer = loadJapaneseTokenizer(dir.path);
    setUpAll(() {
      dir = Directory.systemTemp.createTempSync("ipadic");
      _embedded.forEach((name, bytes) => File("${dir.path}/$name").writeAsBytesSync(bytes));
    });
    tearDownAll(() => dir.deleteSync(recursive: true));

    test("pinned download hashes match the package's dictionary", () {
      for (final MapEntry(key: name, value: (hash, size)) in JapaneseDictionary.files.entries) {
        final bytes = _embedded[name]!;
        expect(bytes.length, size, reason: name);
        expect(sha256.convert(bytes).toString(), hash, reason: name);
      }
    });

    test("annotates sample lyric lines", () {
      final line = annotateLine(tokenizer, "夜空に輝く星を見上げた");
      final readings = {for (final r in line.ruby) "夜空に輝く星を見上げた".substring(r.start, r.end): r.reading};
      expect(readings, {"夜空": "よぞら", "輝": "かがや", "星": "ほし", "見上": "みあ"});
      expect(line.romaji, "yozora ni kagayaku hoshi o miage ta");
    });

    test("keeps punctuation and positions", () {
      const text = "東京、君の街。";
      final line = annotateLine(tokenizer, text);
      expect(line.ruby.map((r) => text.substring(r.start, r.end)), ["東京", "君", "街"]);
      expect(line.ruby.first.reading, "とうきょう");
    });

    test("latin and kana lines are unchanged", () {
      expect(annotateLine(tokenizer, "I love you").isEmpty, isTrue);
      expect(annotateLine(tokenizer, "ありがとう").ruby, isEmpty);
    });
  });
}
