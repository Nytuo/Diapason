import 'dart:convert';
import 'dart:typed_data';

import 'package:diapason/services/tag_editor/formats/ogg_tags.dart';
import 'package:diapason/services/tag_editor/formats/vorbis_comment.dart';

/// Minimal synthetic audio containers: just enough structure for the tag
/// codecs, with a recognisable "audio" payload whose bytes must survive.

Uint8List fakeAudioPayload([int length = 3000]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + 7) & 0xFF));

/// MPEG frames (sync word + junk), optionally preceded by [id3].
Uint8List buildMp3({List<int> id3 = const []}) {
  final audio = fakeAudioPayload();
  audio[0] = 0xFF;
  audio[1] = 0xFB;
  return Uint8List.fromList([...id3, ...audio]);
}

/// A raw ID3v2.3 tag with a TIT2, a custom TXXX and a PRIV frame.
Uint8List buildId3v23Tag() {
  List<int> frame(String id, List<int> data) {
    final size = ByteData(4)..setUint32(0, data.length);
    return [...ascii.encode(id), ...size.buffer.asUint8List(), 0, 0, ...data];
  }

  final frames = [
    ...frame("TIT2", [0, ...latin1.encode("Old title")]),
    ...frame("TXXX", [0, ...latin1.encode("Custom"), 0, ...latin1.encode("keep me")]),
    ...frame("PRIV", [...latin1.encode("owner"), 0, 1, 2, 3]),
  ];
  const padding = 64;
  final size = frames.length + padding;
  return Uint8List.fromList([
    0x49, 0x44, 0x33, 3, 0, 0, //
    (size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F,
    ...frames,
    ...List.filled(padding, 0),
  ]);
}

/// "fLaC" + STREAMINFO + optional VORBIS_COMMENT + an APPLICATION block, then audio.
Uint8List buildFlac({VorbisComment? comment}) {
  List<int> block(int type, List<int> data, {bool last = false}) => [
    (last ? 0x80 : 0) | type,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
    ...data,
  ];
  return Uint8List.fromList([
    ...ascii.encode("fLaC"),
    ...block(0, List.generate(34, (i) => i)),
    if (comment != null) ...block(4, comment.serialize()),
    ...block(2, [...ascii.encode("TEST"), 9, 9, 9], last: true),
    ...fakeAudioPayload(),
  ]);
}

/// Ogg Opus: identification page (BOS), comment page, then [audioPages]
/// audio pages with increasing granule positions.
Uint8List buildOpus({int audioPages = 3, VorbisComment? comment}) {
  const serial = 0x1234;
  final head = Uint8List.fromList([...ascii.encode("OpusHead"), 1, 2, 0x38, 1, 0x80, 0xBB, 0, 0, 0, 0, 0]);
  final idPage = OggTags.paginate([head], serial: serial, firstSequence: 0).single;
  idPage[5] = 2; // BOS
  _fixCrc(idPage);
  final tags = Uint8List.fromList([
    ...ascii.encode("OpusTags"),
    ...(comment ?? VorbisComment(vendor: "test")).serialize(),
  ]);
  final commentPages = OggTags.paginate([tags], serial: serial, firstSequence: 1);
  final out = BytesBuilder()
    ..add(idPage)
    ..add(commentPages.expand((p) => p).toList());
  var sequence = 1 + commentPages.length;
  for (var i = 0; i < audioPages; i++) {
    final page = OggTags.paginate([fakeAudioPayload(200 + i)], serial: serial, firstSequence: sequence++).single;
    ByteData.sublistView(page).setInt64(6, 960 * (i + 1), Endian.little);
    if (i == audioPages - 1) page[5] |= 4; // EOS
    _fixCrc(page);
    out.add(page);
  }
  return out.toBytes();
}

void _fixCrc(Uint8List page) {
  final d = ByteData.sublistView(page)..setUint32(22, 0, Endian.little);
  d.setUint32(22, OggTags.oggCrc(page), Endian.little);
}

/// Parsed Ogg pages, for assertions.
List<({int sequence, int granule, int flags, Uint8List body, bool crcOk})> parseOggPages(Uint8List bytes) {
  final pages = <({int sequence, int granule, int flags, Uint8List body, bool crcOk})>[];
  var pos = 0;
  while (pos + 27 <= bytes.length) {
    final d = ByteData.sublistView(bytes, pos);
    final segments = bytes[pos + 26];
    final lacing = bytes.sublist(pos + 27, pos + 27 + segments);
    final bodyLength = lacing.fold<int>(0, (a, b) => a + b);
    final total = 27 + segments + bodyLength;
    final page = Uint8List.fromList(bytes.sublist(pos, pos + total));
    final storedCrc = ByteData.sublistView(page).getUint32(22, Endian.little);
    ByteData.sublistView(page).setUint32(22, 0, Endian.little);
    pages.add((
      sequence: d.getUint32(18, Endian.little),
      granule: d.getInt64(6, Endian.little),
      flags: bytes[pos + 5],
      body: Uint8List.sublistView(bytes, pos + 27 + segments, pos + total),
      crcOk: OggTags.oggCrc(page) == storedCrc,
    ));
    pos += total;
  }
  return pages;
}

List<int> _box(String type, List<int> payload) {
  final size = ByteData(4)..setUint32(0, payload.length + 8);
  return [...size.buffer.asUint8List(), ...latin1.encode(type), ...payload];
}

/// ftyp + moov (mvhd, trak with one stco entry) + mdat. With [moovFirst] the
/// chunk offset points after moov, which forces offset patching on resize.
Uint8List buildMp4({bool moovFirst = true, List<int>? ilst}) {
  final ftyp = _box("ftyp", [...latin1.encode("M4A "), 0, 0, 0, 0, ...latin1.encode("M4A isom")]);
  final audio = fakeAudioPayload();
  List<int> moov(int chunkOffset) {
    final stco = _box("stco", [
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      ...(ByteData(4)..setUint32(0, chunkOffset)).buffer.asUint8List(),
    ]);
    final trak = _box("trak", _box("mdia", _box("minf", _box("stbl", stco))));
    final udta = ilst == null ? <int>[] : _box("udta", _box("meta", [0, 0, 0, 0, ..._box("ilst", ilst)]));
    return _box("moov", [
      ..._box("mvhd", [...List.filled(12, 0), 0, 0, 0xAC, 0x44, 0, 0, 0xAC, 0x44, ...List.filled(84, 0)]),
      ...trak,
      ...udta,
    ]);
  }

  if (moovFirst) {
    final moovLength = moov(0).length;
    final mdatStart = ftyp.length + moovLength;
    return Uint8List.fromList([...ftyp, ...moov(mdatStart + 8), ..._box("mdat", audio)]);
  }
  final mdatStart = ftyp.length;
  return Uint8List.fromList([...ftyp, ..._box("mdat", audio), ...moov(mdatStart + 8)]);
}

/// Reads the single stco offset of a file built by [buildMp4].
int readStcoOffset(Uint8List bytes) {
  final i = _indexOf(bytes, latin1.encode("stco"));
  return ByteData.sublistView(bytes).getUint32(i + 4 + 8);
}

int _indexOf(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Index of [needle] in [haystack], or -1.
int indexOfBytes(Uint8List haystack, List<int> needle) => _indexOf(haystack, needle);
