// Parses M4A/MP4 `chpl` (Nero-style chapter list) atoms.
//
// For local files, this uses the audio_metadata_reader package's MP4Parser,
// which already implements this correctly (unlike its ID3v2 parser, which
// declares chapter support but never implements CHAP frames -- see
// id3_chapter_parser.dart).
//
// For streamed (not downloaded) files, MP4Parser can't be used: it needs
// random access across the whole file, since `moov` (which chapters live
// under) can sit anywhere depending on the encoder -- "faststart" encoders
// put it up front, but many instead append it after all the audio data once
// encoding finishes, since they don't know the final layout ahead of time.
// tryParseM4aBytes below is a best-effort, leading-bytes-only walk of the
// same box tree: it finds chapters when `moov` happens to be up front, and
// gives up (no chapters, not a second fetch) the moment it isn't -- chasing
// `moov` at the end of a possibly huge file isn't worth the complexity.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:logging/logging.dart';

import '../models/jellyfin_models.dart' as jellyfin_models;

final _log = Logger("M4aChapterParser");

Future<List<jellyfin_models.ChapterInfo>> parseM4aChaptersFromFile(File file) async {
  try {
    final raf = await file.open();
    if (!MP4Parser.canUserParser(raf)) {
      await raf.close();
      return const [];
    }
    // MP4Parser.parse() closes the RandomAccessFile itself once done.
    final metadata = MP4Parser(fetchImage: false).parse(raf);
    return _sortedChapters(metadata.chapters);
  } catch (e) {
    _log.fine("Failed to parse M4A chapters for '${file.path}': $e");
    return const [];
  }
}

/// Returns null if [bytes] doesn't start with an MP4/M4A `ftyp` signature,
/// so callers can fall through to trying other tag formats.
List<jellyfin_models.ChapterInfo>? tryParseM4aBytes(Uint8List bytes) {
  if (bytes.length < 8 || _ascii(bytes, 4, 8) != "ftyp") return null;

  var offset = 0;
  while (offset + 8 <= bytes.length) {
    final box = _readBoxHeader(bytes, offset);
    if (box == null) break;
    final boxEnd = offset + box.size;

    if (box.type == "moov") {
      if (boxEnd > bytes.length) break; // moov itself got truncated by our fetch
      final chplPayload = _findChplPayload(bytes, offset + box.headerSize, boxEnd);
      return chplPayload == null ? const [] : _sortedChapters(_parseChapterListBox(chplPayload));
    }
    if (box.type == "mdat") break; // best effort: moov isn't up front, not chasing it

    if (box.size <= 0 || boxEnd > bytes.length) break;
    offset = boxEnd;
  }
  return const [];
}

List<jellyfin_models.ChapterInfo> _sortedChapters(List<Chapter> raw) {
  if (raw.isEmpty) return const [];
  final chapters = raw
      .map(
        (c) => jellyfin_models.ChapterInfo(
          startPositionTicks: c.start.inMicroseconds * 10,
          name: c.title.isEmpty ? null : c.title,
          imageDateModified: "",
        ),
      )
      .toList();
  chapters.sort((a, b) => a.startPositionTicks.compareTo(b.startPositionTicks));
  return chapters;
}

const _containerBoxTypes = {"moov", "udta", "trak", "mdia", "minf", "stbl"};

/// Recursively searches `bytes[start..end)` for a `chpl` box, descending
/// into the small set of MP4 container boxes that could plausibly hold one.
Uint8List? _findChplPayload(Uint8List bytes, int start, int end, {int depth = 0}) {
  if (depth > 6) return null;
  var offset = start;
  while (offset + 8 <= end) {
    final box = _readBoxHeader(bytes, offset);
    if (box == null) return null;
    final bodyStart = offset + box.headerSize;
    final boxEnd = offset + box.size;
    if (box.size <= 0 || boxEnd > end) return null;

    if (box.type == "chpl") return bytes.sublist(bodyStart, boxEnd);

    if (box.type == "meta") {
      // `meta` is a full box: 1 byte version + 3 bytes flags before children.
      final found = _findChplPayload(bytes, bodyStart + 4, boxEnd, depth: depth + 1);
      if (found != null) return found;
    } else if (_containerBoxTypes.contains(box.type)) {
      final found = _findChplPayload(bytes, bodyStart, boxEnd, depth: depth + 1);
      if (found != null) return found;
    }

    offset = boxEnd;
  }
  return null;
}

class _BoxHeader {
  _BoxHeader(this.size, this.headerSize, this.type);
  final int size;
  final int headerSize;
  final String type;
}

_BoxHeader? _readBoxHeader(Uint8List bytes, int offset) {
  if (offset + 8 > bytes.length) return null;
  final size32 = _beUint32(bytes, offset);
  final type = _ascii(bytes, offset + 4, offset + 8);

  if (size32 == 1) {
    if (offset + 16 > bytes.length) return null;
    return _BoxHeader(_beUint64(bytes, offset + 8), 16, type);
  }
  if (size32 == 0) {
    // Box runs to the end of the file; we don't know the real file length
    // here, so treat it as running to the end of what we fetched.
    return _BoxHeader(bytes.length - offset, 8, type);
  }
  return _BoxHeader(size32, 8, type);
}

/// Parses a `chpl` box body. Mirrors audio_metadata_reader's own parsing
/// (see MP4Parser._parseChapterListBox), which handles both layouts found
/// in the wild -- with or without a 4-byte reserved field before the
/// chapter count -- by trying both and keeping whichever parses cleanly.
List<Chapter> _parseChapterListBox(Uint8List value) {
  if (value.length < 5) return const [];
  final withReserved = _extractChapterEntries(value, chapterCountOffset: 8);
  final withoutReserved = _extractChapterEntries(value, chapterCountOffset: 4);
  if (withReserved == null) return withoutReserved ?? const [];
  if (withoutReserved == null) return withReserved;
  return withoutReserved.length > withReserved.length ? withoutReserved : withReserved;
}

List<Chapter>? _extractChapterEntries(Uint8List value, {required int chapterCountOffset}) {
  if (chapterCountOffset >= value.length) return null;
  var offset = chapterCountOffset;
  final chapterCount = value[offset];
  offset += 1;

  final chapters = <Chapter>[];
  for (var i = 0; i < chapterCount; i++) {
    if (offset + 9 > value.length) return null;
    final startIn100Nanoseconds = _beUint64(value, offset);
    offset += 8;
    final titleLength = value[offset];
    offset += 1;
    if (offset + titleLength > value.length) return null;
    final titleBytes = value.sublist(offset, offset + titleLength);
    offset += titleLength;
    chapters.add(
      Chapter(
        start: Duration(microseconds: (startIn100Nanoseconds / 10).round()),
        title: _decodeM4aString(titleBytes),
      ),
    );
  }
  return chapters;
}

String _decodeM4aString(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes);
  }
}

String _ascii(Uint8List bytes, int start, int end) => ascii.decode(bytes.sublist(start, end), allowInvalid: true);

int _beUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];

int _beUint64(Uint8List bytes, int offset) {
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value = (value << 8) | bytes[offset + i];
  }
  return value;
}
