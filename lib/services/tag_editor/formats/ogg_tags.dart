import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/formats/file_rewrite.dart';
import 'package:diapason/services/tag_editor/formats/vorbis_comment.dart';

/// Ogg Vorbis and Ogg Opus comment headers.
///
/// The comment lives in the second packet of the first logical stream. Writing
/// re-paginates the header packets after the identification page, then
/// renumbers the following pages of that stream (with fresh CRCs) when the
/// header page count changed. Audio packets are never re-paginated.
abstract final class OggTags {
  static Future<AudioTags> read(File file) async {
    final headers = await _readHeaders(file);
    return headers.comment.toTags();
  }

  static Future<void> write(File file, AudioTags tags) async {
    final headers = await _readHeaders(file);
    final comment = headers.comment..applyTags(tags, embedPictures: true);

    final packets = <Uint8List>[headers.codec.encodeComment(comment), ...headers.trailingHeaderPackets];
    final newPages = paginate(packets, serial: headers.serial, firstSequence: 1);
    final delta = newPages.length - headers.oldHeaderPageCount;

    final head = BytesBuilder(copy: false)
      ..add(headers.firstPage)
      ..add(newPages.expand((p) => p).toList());

    await rewriteFile(file, [
      BytesSegment(head.toBytes()),
      if (delta == 0)
        SourceRange(headers.audioOffset)
      else
        StreamSegment(() => _renumbered(file, headers.audioOffset, headers.serial, delta)),
    ]);
  }

  static Stream<List<int>> _renumbered(File file, int start, int serial, int delta) async* {
    final raf = await file.open();
    try {
      final length = await raf.length();
      var pos = start;
      while (pos < length) {
        final page = await _readPage(raf, pos);
        if (page == null) {
          // Trailing garbage after the last page: copy it verbatim.
          yield await readRange(raf, pos, length - pos);
          break;
        }
        final bytes = page.bytes;
        if (page.serial == serial) {
          final data = ByteData.sublistView(bytes);
          data.setUint32(18, (page.sequence + delta) & 0xFFFFFFFF, Endian.little);
          data.setUint32(22, 0, Endian.little);
          data.setUint32(22, oggCrc(bytes), Endian.little);
        }
        yield bytes;
        pos += bytes.length;
      }
    } finally {
      await raf.close();
    }
  }

  static Future<_Headers> _readHeaders(File file) async {
    final raf = await file.open();
    try {
      final first = await _readPage(raf, 0);
      if (first == null) throw const UnsupportedTagFormatException("Not an Ogg file");
      final serial = first.serial;
      final firstPackets = first.completePacketCount;
      if (first.lacing.isEmpty || first.lacing.last == 255 || firstPackets != 1) {
        throw const UnsupportedTagFormatException("Unexpected Ogg identification page layout");
      }
      final idPacket = first.body;
      final codec = _OggCodec.detect(idPacket);
      if (codec == null) throw const UnsupportedTagFormatException("Only Ogg Vorbis and Opus are supported");

      final packets = <Uint8List>[];
      var current = BytesBuilder(copy: false);
      var pos = first.bytes.length;
      var headerPages = 0;
      while (packets.length < codec.headerPackets - 1) {
        final page = await _readPage(raf, pos);
        if (page == null) throw const FormatException("Truncated Ogg headers");
        if (page.serial != serial) {
          throw const UnsupportedTagFormatException("Multiplexed Ogg streams are not supported");
        }
        headerPages++;
        pos += page.bytes.length;
        var offset = 0;
        for (var i = 0; i < page.lacing.length; i++) {
          final l = page.lacing[i];
          current.add(Uint8List.sublistView(page.body, offset, offset + l));
          offset += l;
          if (l < 255) {
            packets.add(current.toBytes());
            current = BytesBuilder(copy: false);
            if (packets.length == codec.headerPackets - 1 && i != page.lacing.length - 1) {
              throw const UnsupportedTagFormatException("Audio data shares a page with the Ogg headers");
            }
          }
        }
      }
      return _Headers(
        codec: codec,
        serial: serial,
        firstPage: first.bytes,
        comment: codec.decodeComment(packets.first),
        trailingHeaderPackets: packets.sublist(1),
        oldHeaderPageCount: headerPages,
        audioOffset: pos,
      );
    } finally {
      await raf.close();
    }
  }

  static Future<_Page?> _readPage(RandomAccessFile raf, int pos) async {
    final header = await readRange(raf, pos, 27);
    if (header.length < 27 || header[0] != 0x4F || header[1] != 0x67 || header[2] != 0x67 || header[3] != 0x53) {
      return null;
    }
    final segments = header[26];
    final lacing = await readRange(raf, pos + 27, segments);
    if (lacing.length < segments) return null;
    final bodyLength = lacing.fold<int>(0, (a, b) => a + b);
    final body = await readRange(raf, pos + 27 + segments, bodyLength);
    if (body.length < bodyLength) return null;
    final bytes = Uint8List(27 + segments + bodyLength)
      ..setAll(0, header)
      ..setAll(27, lacing)
      ..setAll(27 + segments, body);
    return _Page(bytes, segments);
  }

  /// Splits [packets] into Ogg pages (header pages: granule 0 when a packet
  /// ends on the page, -1 otherwise).
  static List<Uint8List> paginate(List<Uint8List> packets, {required int serial, required int firstSequence}) {
    final segments = <({int length, int packet, int offset, bool last})>[];
    for (var p = 0; p < packets.length; p++) {
      final len = packets[p].length;
      final full = len ~/ 255;
      for (var i = 0; i < full; i++) {
        segments.add((length: 255, packet: p, offset: i * 255, last: false));
      }
      segments.add((length: len % 255, packet: p, offset: full * 255, last: true));
    }

    final pages = <Uint8List>[];
    var sequence = firstSequence;
    for (var start = 0; start < segments.length; start += 255) {
      final chunk = segments.sublist(start, start + 255 > segments.length ? segments.length : start + 255);
      final continued = chunk.first.offset > 0;
      final completes = chunk.any((s) => s.last);
      final bodyLength = chunk.fold<int>(0, (a, s) => a + s.length);
      final page = Uint8List(27 + chunk.length + bodyLength);
      final data = ByteData.sublistView(page);
      page.setAll(0, const [0x4F, 0x67, 0x67, 0x53, 0]);
      page[5] = continued ? 1 : 0;
      data.setInt64(6, completes ? 0 : -1, Endian.little);
      data.setUint32(14, serial, Endian.little);
      data.setUint32(18, sequence++, Endian.little);
      page[26] = chunk.length;
      var o = 27;
      for (final s in chunk) {
        page[o++] = s.length;
      }
      for (final s in chunk) {
        page.setRange(o, o + s.length, packets[s.packet], s.offset);
        o += s.length;
      }
      data.setUint32(22, oggCrc(page), Endian.little);
      pages.add(page);
    }
    return pages;
  }

  static final Uint32List _crcTable = () {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var r = i << 24;
      for (var j = 0; j < 8; j++) {
        r = (r & 0x80000000) != 0 ? ((r << 1) ^ 0x04C11DB7) : (r << 1);
        r &= 0xFFFFFFFF;
      }
      table[i] = r;
    }
    return table;
  }();

  /// Ogg page CRC (the CRC field itself must be zeroed by the caller).
  static int oggCrc(Uint8List page) {
    var crc = 0;
    for (final b in page) {
      crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) & 0xFF) ^ b];
    }
    return crc;
  }
}

class _Page {
  _Page(this.bytes, int segments)
    : lacing = Uint8List.sublistView(bytes, 27, 27 + segments),
      body = Uint8List.sublistView(bytes, 27 + segments);

  final Uint8List bytes;
  final Uint8List lacing;
  final Uint8List body;

  int get serial => ByteData.sublistView(bytes).getUint32(14, Endian.little);
  int get sequence => ByteData.sublistView(bytes).getUint32(18, Endian.little);
  int get completePacketCount => lacing.where((l) => l < 255).length;
}

class _Headers {
  _Headers({
    required this.codec,
    required this.serial,
    required this.firstPage,
    required this.comment,
    required this.trailingHeaderPackets,
    required this.oldHeaderPageCount,
    required this.audioOffset,
  });

  final _OggCodec codec;
  final int serial;
  final Uint8List firstPage;
  final VorbisComment comment;
  final List<Uint8List> trailingHeaderPackets;
  final int oldHeaderPageCount;
  final int audioOffset;
}

enum _OggCodec {
  vorbis(3, [0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]),
  opus(2, [0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73]);

  const _OggCodec(this.headerPackets, this.commentPrefix);

  final int headerPackets;
  final List<int> commentPrefix;

  static _OggCodec? detect(Uint8List idPacket) {
    bool startsWith(String s) =>
        idPacket.length >= s.length && String.fromCharCodes(idPacket.sublist(0, s.length)) == s;
    if (startsWith("\x01vorbis")) return vorbis;
    if (startsWith("OpusHead")) return opus;
    return null;
  }

  VorbisComment decodeComment(Uint8List packet) {
    if (packet.length < commentPrefix.length ||
        !List.generate(commentPrefix.length, (i) => packet[i] == commentPrefix[i]).every((ok) => ok)) {
      throw const FormatException("Missing Ogg comment header");
    }
    return VorbisComment.parse(packet, commentPrefix.length);
  }

  Uint8List encodeComment(VorbisComment comment) {
    final out = BytesBuilder(copy: false)
      ..add(commentPrefix)
      ..add(comment.serialize());
    // Vorbis requires the framing bit; Opus has none.
    if (this == vorbis) out.addByte(1);
    return out.toBytes();
  }
}
