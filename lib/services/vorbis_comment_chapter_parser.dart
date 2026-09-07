// Parses `CHAPTERxxx`/`CHAPTERxxxNAME` Vorbis comment fields -- the de
// facto convention (used by foobar2000, mkvmerge, ffmpeg, VLC, etc.) for
// storing chapters in FLAC and Ogg (Vorbis/Opus) files. Neither format has
// a Jellyfin-style chapters API equivalent, so for backends without one
// (Navidrome/Subsonic, Plex, local files) this is read straight out of the
// file itself, same as the ID3v2 CHAP parser for MP3.

import 'dart:convert';
import 'dart:typed_data';

import '../models/jellyfin_models.dart' as jellyfin_models;

/// Returns null if [bytes] doesn't start with a FLAC signature, so callers
/// can fall through to trying other tag formats.
List<jellyfin_models.ChapterInfo>? tryParseFlacBytes(Uint8List bytes) {
  if (bytes.length < 4 || _ascii(bytes, 0, 4) != "fLaC") return null;

  var offset = 4;
  while (offset + 4 <= bytes.length) {
    final headerByte = bytes[offset];
    final isLastBlock = headerByte & 0x80 != 0;
    final blockType = headerByte & 0x7F;
    final length = (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
    final blockStart = offset + 4;
    final blockEnd = blockStart + length;

    if (blockType == 4) {
      // VORBIS_COMMENT
      if (blockEnd > bytes.length) return const [];
      return _chaptersFromCommentMap(_parseCommentBlock(bytes, blockStart, blockEnd));
    }

    if (blockEnd > bytes.length) return const []; // can't skip past data we don't have
    offset = blockEnd;
    if (isLastBlock) break;
  }
  return const [];
}

/// Returns null if [bytes] doesn't start with an Ogg page signature, so
/// callers can fall through to trying other tag formats.
List<jellyfin_models.ChapterInfo>? tryParseOggBytes(Uint8List bytes) {
  if (bytes.length < 4 || _ascii(bytes, 0, 4) != "OggS") return null;

  // Reassemble the stream's logical packets from its physical pages until we
  // have the first two (identification header, comment header) or run out
  // of fetched data.
  final packets = <Uint8List>[];
  var packetBuilder = BytesBuilder();
  var offset = 0;
  int? streamSerial;

  while (offset + 27 <= bytes.length && packets.length < 2) {
    if (_ascii(bytes, offset, offset + 4) != "OggS") break;
    final serial = _leUint32(bytes, offset + 14);
    streamSerial ??= serial;
    if (serial != streamSerial) break; // ignore other multiplexed streams

    final segmentCount = bytes[offset + 26];
    final segTableStart = offset + 27;
    if (segTableStart + segmentCount > bytes.length) break;
    final segTable = bytes.sublist(segTableStart, segTableStart + segmentCount);
    var dataOffset = segTableStart + segmentCount;

    for (final segLen in segTable) {
      if (dataOffset + segLen > bytes.length) return _packetsToChapters(packets);
      packetBuilder.add(bytes.sublist(dataOffset, dataOffset + segLen));
      dataOffset += segLen;
      if (segLen < 255) {
        packets.add(packetBuilder.toBytes());
        packetBuilder = BytesBuilder();
        if (packets.length >= 2) break;
      }
    }
    offset = dataOffset;
  }

  return _packetsToChapters(packets);
}

List<jellyfin_models.ChapterInfo> _packetsToChapters(List<Uint8List> packets) {
  if (packets.length < 2) return const [];
  final commentPacket = packets[1];

  Map<String, String>? comments;
  if (commentPacket.length >= 8 && _ascii(commentPacket, 0, 8) == "OpusTags") {
    comments = _parseCommentBlock(commentPacket, 8, commentPacket.length);
  } else if (commentPacket.length >= 7 && commentPacket[0] == 0x03 && _ascii(commentPacket, 1, 7) == "vorbis") {
    comments = _parseCommentBlock(commentPacket, 7, commentPacket.length);
  }
  if (comments == null) return const [];
  return _chaptersFromCommentMap(comments);
}

/// Parses a raw Vorbis comment block (vendor string + `KEY=VALUE` list) in
/// `bytes[start..end)`, common to the FLAC VORBIS_COMMENT block, Ogg Vorbis
/// comment header, and Ogg Opus comment header alike.
Map<String, String> _parseCommentBlock(Uint8List bytes, int start, int end) {
  final comments = <String, String>{};
  var offset = start;
  if (offset + 4 > end) return comments;
  final vendorLength = _leUint32(bytes, offset);
  offset += 4 + vendorLength;
  if (offset + 4 > end) return comments;
  final count = _leUint32(bytes, offset);
  offset += 4;

  for (var i = 0; i < count; i++) {
    if (offset + 4 > end) break;
    final len = _leUint32(bytes, offset);
    offset += 4;
    if (offset + len > end) break;
    final raw = utf8.decode(bytes.sublist(offset, offset + len), allowMalformed: true);
    offset += len;
    final eq = raw.indexOf("=");
    if (eq > 0) comments[raw.substring(0, eq).toUpperCase()] = raw.substring(eq + 1);
  }
  return comments;
}

final _chapterFieldPattern = RegExp(r"^CHAPTER(\d+)(NAME)?$");
final _timestampPattern = RegExp(r"^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$");

List<jellyfin_models.ChapterInfo> _chaptersFromCommentMap(Map<String, String> comments) {
  final starts = <int, Duration>{};
  final names = <int, String>{};

  for (final entry in comments.entries) {
    final match = _chapterFieldPattern.firstMatch(entry.key);
    if (match == null) continue;
    final index = int.parse(match.group(1)!);
    if (match.group(2) == null) {
      final start = _parseVorbisTimestamp(entry.value);
      if (start != null) starts[index] = start;
    } else {
      final name = entry.value.trim();
      if (name.isNotEmpty) names[index] = name;
    }
  }

  final chapters = starts.entries
      .map(
        (e) => jellyfin_models.ChapterInfo(
          startPositionTicks: e.value.inMicroseconds * 10,
          name: names[e.key],
          imageDateModified: "",
        ),
      )
      .toList();
  chapters.sort((a, b) => a.startPositionTicks.compareTo(b.startPositionTicks));
  return chapters;
}

/// Parses the `HH:MM:SS[.mmm]` timestamp format chapter comment fields use.
Duration? _parseVorbisTimestamp(String value) {
  final match = _timestampPattern.firstMatch(value.trim());
  if (match == null) return null;
  final fraction = match.group(4);
  final millis = fraction == null ? 0 : int.parse(fraction.padRight(3, "0").substring(0, 3));
  return Duration(
    hours: int.parse(match.group(1)!),
    minutes: int.parse(match.group(2)!),
    seconds: int.parse(match.group(3)!),
    milliseconds: millis,
  );
}

String _ascii(Uint8List bytes, int start, int end) => ascii.decode(bytes.sublist(start, end), allowInvalid: true);

int _leUint32(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
