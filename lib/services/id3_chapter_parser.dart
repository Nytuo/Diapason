import 'dart:convert';
import 'dart:typed_data';

import '../models/jellyfin_models.dart' as jellyfin_models;

/// Parses ID3v2 `CHAP` (chapter) frames out of the leading bytes of an MP3
/// (or any other file with a prepended ID3v2 tag), for backends
/// (Navidrome/Subsonic, Plex, local files) that have no chapters concept in
/// their own API — unlike Jellyfin, which returns chapters directly.
///
/// Returns null if [bytes] doesn't start with a supported (v2.3/v2.4) ID3v2
/// tag, so callers can fall through to trying other tag formats.
List<jellyfin_models.ChapterInfo>? tryParseId3Bytes(Uint8List bytes) {
  if (_id3TagSize(bytes) == null) return null;
  return _parseId3Tag(bytes);
}

/// Reads the syncsafe size out of a 10-byte ID3v2 header, or null if [header]
/// isn't a valid, supported (v2.3/v2.4) ID3v2 tag.
int? _id3TagSize(Uint8List header) {
  if (header.length < 10) return null;
  if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) return null; // "ID3"
  final majorVersion = header[3];
  if (majorVersion < 3 || majorVersion > 4) return null; // CHAP wasn't defined before v2.3
  return (header[6] & 0x7F) << 21 | (header[7] & 0x7F) << 14 | (header[8] & 0x7F) << 7 | (header[9] & 0x7F);
}

List<jellyfin_models.ChapterInfo> _parseId3Tag(Uint8List bytes) {
  if (bytes.length < 10) return const [];
  final majorVersion = bytes[3];
  final flags = bytes[5];
  final tagSize = _id3TagSize(bytes);
  if (tagSize == null) return const [];

  var tagEnd = (10 + tagSize).clamp(0, bytes.length);
  var body = bytes;
  if (flags & 0x80 != 0) {
    // Global unsynchronisation: 0xFF 0x00 sequences were inserted to avoid
    // false MPEG sync signals and need to be collapsed back out.
    final unsynced = _removeUnsynchronization(bytes.sublist(10, tagEnd));
    body = Uint8List(10 + unsynced.length)
      ..setRange(0, 10, bytes)
      ..setRange(10, 10 + unsynced.length, unsynced);
    tagEnd = body.length;
  }

  var offset = 10;
  if (flags & 0x40 != 0) {
    // Extended header present; skip over it.
    if (offset + 4 > body.length) return const [];
    final extSize = majorVersion >= 4 ? _syncsafe(body, offset) : _beUint32(body, offset);
    offset += extSize;
  }

  final chapters = <jellyfin_models.ChapterInfo>[];
  while (offset + 10 <= tagEnd) {
    final frameIdBytes = body.sublist(offset, offset + 4);
    if (frameIdBytes.every((b) => b == 0)) break; // padding reached

    final frameSize = majorVersion >= 4 ? _syncsafe(body, offset + 4) : _beUint32(body, offset + 4);
    final frameStart = offset + 10;
    final frameEnd = (frameStart + frameSize).clamp(0, tagEnd);
    if (frameSize <= 0 || frameEnd > tagEnd) break;

    if (ascii.decode(frameIdBytes, allowInvalid: true) == "CHAP") {
      final chapter = _parseChapFrame(body, frameStart, frameEnd, majorVersion);
      if (chapter != null) chapters.add(chapter);
    }

    offset = frameEnd;
  }

  chapters.sort((a, b) => a.startPositionTicks.compareTo(b.startPositionTicks));
  return chapters;
}

Uint8List _removeUnsynchronization(Uint8List data) {
  final out = BytesBuilder();
  for (var i = 0; i < data.length; i++) {
    out.addByte(data[i]);
    if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) {
      i++;
    }
  }
  return out.toBytes();
}

int _syncsafe(Uint8List bytes, int offset) =>
    (bytes[offset] & 0x7F) << 21 |
    (bytes[offset + 1] & 0x7F) << 14 |
    (bytes[offset + 2] & 0x7F) << 7 |
    (bytes[offset + 3] & 0x7F);

int _beUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];

/// Parses a single `CHAP` frame's body: a null-terminated element id, a
/// 16-byte block of start/end time+offset, then nested sub-frames (we only
/// care about `TIT2`, the chapter title).
jellyfin_models.ChapterInfo? _parseChapFrame(Uint8List body, int start, int end, int majorVersion) {
  var i = start;
  while (i < end && body[i] != 0) {
    i++;
  }
  if (i + 1 + 16 > end) return null;
  final startTimeMs = _beUint32(body, i + 1);

  String? title;
  var subOffset = i + 1 + 16;
  while (subOffset + 10 <= end) {
    final subIdBytes = body.sublist(subOffset, subOffset + 4);
    if (subIdBytes.every((b) => b == 0)) break;
    final subSize = majorVersion >= 4 ? _syncsafe(body, subOffset + 4) : _beUint32(body, subOffset + 4);
    final subStart = subOffset + 10;
    final subEnd = (subStart + subSize).clamp(0, end);
    if (subSize <= 0 || subEnd > end) break;

    if (ascii.decode(subIdBytes, allowInvalid: true) == "TIT2" && subEnd > subStart) {
      title = _decodeId3Text(body.sublist(subStart, subEnd));
    }

    subOffset = subEnd;
  }

  return jellyfin_models.ChapterInfo(startPositionTicks: startTimeMs * 10000, name: title, imageDateModified: "");
}

String? _decodeId3Text(Uint8List data) {
  if (data.isEmpty) return null;
  final encoding = data[0];
  final textBytes = data.sublist(1);
  String raw;
  switch (encoding) {
    case 1: // UTF-16 with BOM
      raw = _decodeUtf16(textBytes);
    case 2: // UTF-16BE without BOM
      raw = _decodeUtf16(textBytes, bigEndianDefault: true);
    case 3: // UTF-8
      raw = utf8.decode(textBytes, allowMalformed: true);
    default: // 0: ISO-8859-1 (Latin-1)
      raw = latin1.decode(textBytes, allowInvalid: true);
  }
  final trimmed = raw.replaceAll(RegExp(r"[\x00\s]+$"), "");
  return trimmed.isEmpty ? null : trimmed;
}

String _decodeUtf16(Uint8List bytes, {bool bigEndianDefault = false}) {
  if (bytes.length < 2) return "";
  var bigEndian = bigEndianDefault;
  var start = 0;
  if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
    bigEndian = false;
    start = 2;
  } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
    bigEndian = true;
    start = 2;
  }
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(bigEndian ? (bytes[i] << 8) | bytes[i + 1] : (bytes[i + 1] << 8) | bytes[i]);
  }
  return String.fromCharCodes(units);
}
