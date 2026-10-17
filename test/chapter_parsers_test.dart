import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/id3_chapter_parser.dart';
import 'package:diapason/services/m4a_chapter_parser.dart';
import 'package:diapason/services/vorbis_comment_chapter_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(List<int> v) => Uint8List.fromList(v);
List<int> _be32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];
List<int> _le32(int v) => _be32(v).reversed.toList();
List<int> _syncsafe(int v) => [(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F];

// ---- ID3 -------------------------------------------------------------------

List<int> _tit2(String title, {int encoding = 3, int version = 4, List<int>? raw}) {
  final body = [encoding, ...(raw ?? utf8.encode(title))];
  return [...ascii.encode('TIT2'), ...(version >= 4 ? _syncsafe(body.length) : _be32(body.length)), 0, 0, ...body];
}

List<int> _chap(String id, int startMs, List<int> subframes, {int version = 4}) {
  final body = [
    ...ascii.encode(id),
    0,
    ..._be32(startMs),
    ..._be32(startMs + 1000),
    ..._be32(0),
    ..._be32(0),
    ...subframes,
  ];
  return [...ascii.encode('CHAP'), ...(version >= 4 ? _syncsafe(body.length) : _be32(body.length)), 0, 0, ...body];
}

Uint8List _id3(List<List<int>> frames, {int version = 4, int flags = 0, List<int> pad = const []}) {
  final body = [...frames.expand((f) => f), ...pad];
  return _b([...ascii.encode('ID3'), version, 0, flags, ..._syncsafe(body.length), ...body]);
}

// ---- MP4 -------------------------------------------------------------------

List<int> _box(String type, List<int> body) => [..._be32(8 + body.length), ...ascii.encode(type), ...body];

List<int> _chplBody(List<(int, String)> chapters, {bool reserved = true}) {
  final entries = chapters.expand((c) {
    final t = utf8.encode(c.$2);
    return [...List.filled(4, 0), ..._be32(c.$1 * 10000), t.length, ...t];
  });
  // 8 bytes of version/flags/reserved precede the count in one layout, 4 in the other.
  return [...List.filled(reserved ? 8 : 4, 0), chapters.length, ...entries];
}

Uint8List _m4a({required List<int> moov, bool mdatFirst = false}) {
  final ftyp = _box('ftyp', [...ascii.encode('M4A '), 0, 0, 0, 0]);
  final mdat = _box('mdat', List.filled(32, 7));
  return _b([...ftyp, if (mdatFirst) ...mdat, ...moov, if (!mdatFirst) ...mdat]);
}

// ---- Vorbis comments -------------------------------------------------------

List<int> _commentBlock(Map<String, String> fields) {
  final vendor = utf8.encode('test');
  final entries = fields.entries.expand((e) {
    final raw = utf8.encode('${e.key}=${e.value}');
    return [..._le32(raw.length), ...raw];
  });
  return [..._le32(vendor.length), ...vendor, ..._le32(fields.length), ...entries];
}

Uint8List _flac(Map<String, String> fields, {bool commentFirst = false}) {
  final streamInfo = [0, 0, 0, 34, ...List.filled(34, 0)];
  final block = _commentBlock(fields);
  final comment = [0x84, (block.length >> 16) & 255, (block.length >> 8) & 255, block.length & 255, ...block];
  return _b([...ascii.encode('fLaC'), if (!commentFirst) ...streamInfo, ...comment]);
}

List<int> _oggPage(int serial, List<int> packet, {int seq = 0}) {
  final segs = <int>[];
  var left = packet.length;
  while (left >= 255) {
    segs.add(255);
    left -= 255;
  }
  segs.add(left);
  return [
    ...ascii.encode('OggS'),
    0,
    0,
    ...List.filled(8, 0),
    ..._le32(serial),
    ..._le32(seq),
    ...List.filled(4, 0),
    segs.length,
    ...segs,
    ...packet,
  ];
}

void main() {
  group('ID3 CHAP frames', () {
    test('reads titles and start times, sorted by time', () {
      final bytes = _id3([_chap('b', 90000, _tit2('Second')), _chap('a', 1500, _tit2('First'))]);
      final r = tryParseId3Bytes(bytes)!;
      expect(r.map((c) => c.name), ['First', 'Second']);
      expect(r.map((c) => c.startPositionTicks), [1500 * 10000, 90000 * 10000]);
    });

    test('works for v2.3 (plain, not syncsafe, sizes)', () {
      final r = tryParseId3Bytes(_id3([_chap('a', 5000, _tit2('Old tag', version: 3), version: 3)], version: 3))!;
      expect(r.single.name, 'Old tag');
    });

    test('decodes Latin-1, UTF-16 with BOM both ways, UTF-16BE and UTF-8', () {
      String title(int enc, List<int> raw) =>
          tryParseId3Bytes(_id3([_chap('a', 0, _tit2('', encoding: enc, raw: raw))]))!.single.name!;
      expect(title(0, latin1.encode('Café')), 'Café');
      expect(title(1, [0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00]), 'AB');
      expect(title(1, [0xFE, 0xFF, 0x00, 0x41, 0x00, 0x42]), 'AB');
      expect(title(2, [0x00, 0x43]), 'C');
      expect(title(3, utf8.encode('日本')), '日本');
    });

    test('a blank title is no title', () {
      expect(
        tryParseId3Bytes(
          _id3([
            _chap('a', 0, _tit2('', raw: [0])),
          ]),
        )!.single.name,
        isNull,
      );
    });

    test('a chapter without sub-frames has no name', () {
      expect(tryParseId3Bytes(_id3([_chap('a', 2000, [])]))!.single.name, isNull);
    });

    test('padding ends the frame list; other frames are skipped', () {
      final other = [...ascii.encode('TALB'), ..._syncsafe(2), 0, 0, 3, 0x41];
      final r = tryParseId3Bytes(_id3([other, _chap('a', 0, _tit2('X'))], pad: List.filled(20, 0)))!;
      expect(r.single.name, 'X');
    });

    test('not ID3, too short, or an unsupported version fall through with null', () {
      expect(tryParseId3Bytes(_b([1, 2, 3])), isNull);
      expect(tryParseId3Bytes(_b(List.filled(20, 1))), isNull);
      expect(tryParseId3Bytes(_id3([], version: 2)), isNull);
    });

    test('unsynchronisation and an extended header are tolerated', () {
      final frame = _chap('a', 0, _tit2('Hi'));
      expect(tryParseId3Bytes(_id3([frame], flags: 0x80))!.single.name, 'Hi');
      final ext = [..._syncsafe(6), ...List.filled(2, 0)];
      expect(tryParseId3Bytes(_id3([ext, frame], flags: 0x40))!.single.name, 'Hi');
    });

    test('a frame that claims to be larger than the tag stops cleanly', () {
      final bad = [...ascii.encode('CHAP'), ..._syncsafe(5000), 0, 0, 1, 2, 3];
      expect(tryParseId3Bytes(_id3([bad])), isEmpty);
    });
  });

  group('M4A chpl atoms', () {
    final chapters = [(0, 'Intro'), (65000, 'Verse')];

    test('finds chapters in udta/chpl when moov is up front', () {
      final moov = _box('moov', _box('udta', _box('chpl', _chplBody(chapters))));
      final r = tryParseM4aBytes(_m4a(moov: moov))!;
      expect(r.map((c) => c.name), ['Intro', 'Verse']);
      expect(r.last.startPositionTicks, 65000 * 10000);
    });

    test('both chpl layouts (with and without the reserved field) parse', () {
      for (final reserved in [true, false]) {
        final moov = _box('moov', _box('udta', _box('chpl', _chplBody(chapters, reserved: reserved))));
        expect(tryParseM4aBytes(_m4a(moov: moov))!.length, 2, reason: 'reserved=$reserved');
      }
    });

    test('looks through meta (a full box) as well', () {
      final moov = _box('moov', _box('udta', _box('meta', [0, 0, 0, 0, ..._box('chpl', _chplBody(chapters))])));
      expect(tryParseM4aBytes(_m4a(moov: moov))!.length, 2);
    });

    test('no chpl at all is an empty list, not null', () {
      expect(tryParseM4aBytes(_m4a(moov: _box('moov', _box('free', [1, 2]))))!, isEmpty);
    });

    test('moov after mdat is not chased', () {
      final moov = _box('moov', _box('udta', _box('chpl', _chplBody(chapters))));
      expect(tryParseM4aBytes(_m4a(moov: moov, mdatFirst: true))!, isEmpty);
    });

    test('a truncated moov gives up without chapters', () {
      final moov = _box('moov', _box('udta', _box('chpl', _chplBody(chapters))));
      final cut = _m4a(moov: moov).sublist(0, 40);
      expect(tryParseM4aBytes(cut), isEmpty);
    });

    test('64-bit box sizes and a size-0 trailing box are understood', () {
      final inner = _box('udta', _box('chpl', _chplBody(chapters)));
      final big = [..._be32(1), ...ascii.encode('moov'), ...List.filled(4, 0), ..._be32(16 + inner.length), ...inner];
      expect(tryParseM4aBytes(_m4a(moov: big))!.length, 2);
      final toEnd = [..._be32(0), ...ascii.encode('moov'), ...inner];
      expect(tryParseM4aBytes(_m4a(moov: toEnd))!.length, 2);
    });

    test('a title that is not UTF-8 falls back to Latin-1; empty titles become null', () {
      final entries = [
        ...List.filled(8, 0),
        2,
        ...List.filled(4, 0),
        ..._be32(0),
        4,
        ...latin1.encode('Café'),
        ...List.filled(4, 0),
        ..._be32(10000),
        0,
      ];
      final moov = _box('moov', _box('udta', _box('chpl', entries)));
      final r = tryParseM4aBytes(_m4a(moov: moov))!;
      expect(r.first.name, 'Café');
      expect(r.last.name, isNull);
    });

    test('not an MP4 is null; a tiny buffer is null', () {
      expect(tryParseM4aBytes(_b(List.filled(30, 0))), isNull);
      expect(tryParseM4aBytes(_b([1, 2])), isNull);
    });

    test('files: a non-MP4 or missing file yields no chapters instead of throwing', () async {
      final dir = await Directory.systemTemp.createTemp('m4a_test');
      addTearDown(() => dir.delete(recursive: true));
      final junk = File('${dir.path}/x.m4a')..writeAsBytesSync([1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(await parseM4aChaptersFromFile(junk), isEmpty);
      expect(await parseM4aChaptersFromFile(File('${dir.path}/missing.m4a')), isEmpty);
    });
  });

  group('FLAC / Ogg chapter comments', () {
    final fields = {
      'CHAPTER001': '00:00:00.000',
      'CHAPTER001NAME': 'Start',
      'CHAPTER002': '00:01:02.5',
      'CHAPTER002NAME': '  Middle  ',
      'chapter003': '1:00:00',
      'TITLE': 'ignored',
    };

    test('FLAC: reads chapters, trims names, pads fractions, sorts, ignores other fields', () {
      final r = tryParseFlacBytes(_flac(fields))!;
      expect(r.map((c) => c.name), ['Start', 'Middle', null]);
      expect(r.map((c) => c.startPositionTicks), [0, 62500 * 10000, 3600000 * 10000]);
    });

    test('FLAC: a bad timestamp is skipped, a missing comment block is empty, non-FLAC is null', () {
      expect(tryParseFlacBytes(_flac({'CHAPTER001': 'soon'}))!, isEmpty);
      expect(tryParseFlacBytes(_b([...ascii.encode('fLaC'), 0x80, 0, 0, 0]))!, isEmpty);
      expect(tryParseFlacBytes(_b([1, 2, 3, 4, 5])), isNull);
    });

    test('FLAC: a truncated block is survived', () {
      final full = _flac(fields);
      expect(tryParseFlacBytes(full.sublist(0, full.length - 10))!, isEmpty);
    });

    test('Ogg Vorbis and Opus: comment packet is the second one', () {
      final comments = _commentBlock(fields);
      final vorbis = [3, ...ascii.encode('vorbis'), ...comments, 1];
      final opus = [...ascii.encode('OpusTags'), ...comments];
      for (final second in [vorbis, opus]) {
        final bytes = _b([
          ..._oggPage(7, [1, 2, 3, 4]),
          ..._oggPage(7, second, seq: 1),
        ]);
        expect(tryParseOggBytes(bytes)!.length, 3);
      }
    });

    test('Ogg: a packet longer than 255 bytes spans segments; other streams are ignored', () {
      final long = {...fields, 'COMMENT': 'x' * 600};
      final second = [...ascii.encode('OpusTags'), ..._commentBlock(long)];
      final bytes = _b([
        ..._oggPage(7, [1]),
        ..._oggPage(99, [9, 9]),
        ..._oggPage(7, second, seq: 1),
      ]);
      // The foreign stream interrupts, so the reader stops rather than mixing data.
      expect(tryParseOggBytes(bytes), isNotNull);
      final clean = _b([
        ..._oggPage(7, [1]),
        ..._oggPage(7, second, seq: 1),
      ]);
      expect(tryParseOggBytes(clean)!.length, 3);
    });

    test('Ogg: not Ogg is null; unknown comment header, too little data, truncation are empty', () {
      expect(tryParseOggBytes(_b([1, 2, 3, 4])), isNull);
      expect(
        tryParseOggBytes(
          _b([
            ..._oggPage(7, [1, 2]),
            ..._oggPage(7, [5, 5, 5, 5, 5, 5, 5, 5, 5], seq: 1),
          ]),
        )!,
        isEmpty,
      );
      expect(tryParseOggBytes(_b(_oggPage(7, [1, 2])))!, isEmpty);
      final page = _oggPage(7, [1, 2, 3]);
      expect(tryParseOggBytes(_b(page.sublist(0, page.length - 2)))!, isEmpty);
    });
  });
}
