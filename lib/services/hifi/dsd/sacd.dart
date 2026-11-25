import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/hifi/dsd/byte_source.dart';
import 'package:diapason/services/hifi/dsd/dsd_container.dart';

/// SACD images (`.iso`): the tables of contents, the packing of the audio sectors, and the tracks of the stereo area
/// handed over as DSD.
///
/// A port of Chilpa's `chilpa-sacd` crate (same layout notes, measured on real discs there). Only the stereo area is
/// read; the multichannel area is ignored. DST-compressed areas are listed and can be re-wrapped as a DSDIFF-DST
/// stream (see [SacdDstStream]) for a player that has a DST decoder (ffmpeg, through mpv); this app has none.

const int sacdSectorSize = 2048;

/// An uncompressed stereo DSD64 frame: 1/75 s, both channels interleaved byte by byte.
const int sacdStereoFrameBytes = 9408;
const int sacdFramesPerSecond = 75;
const int _dataTypeAudio = 2;

/// Where the master table lives, with its two backups.
const List<int> _masterTocLsn = [510, 520, 530];
const int _maxAreaTocSectors = 96;

class SacdFormatException implements Exception {
  SacdFormatException(this.message);

  final String message;

  @override
  String toString() => "SacdFormatException: $message";
}

enum SacdEncoding {
  /// Uncompressed DSD (the "3 in 14" and "3 in 16" layouts store the same bytes for the stereo area).
  dsd,

  /// DST, lossless DSD compression.
  dst,
}

class SacdTrack {
  const SacdTrack({
    required this.number,
    required this.startLsn,
    required this.lengthLsn,
    required this.startFrame,
    required this.durationFrames,
    required this.encoding,
    this.title,
    this.performer,
  });

  final int number;
  final int startLsn;
  final int lengthLsn;

  /// The area timecode of the track's first frame, in 1/75 s.
  final int startFrame;
  final int durationFrames;
  final SacdEncoding encoding;
  final String? title;
  final String? performer;

  Duration get duration => Duration(microseconds: durationFrames * 1000000 ~/ sacdFramesPerSecond);

  @override
  String toString() => "SacdTrack($number, ${title ?? "untitled"}, $duration, ${encoding.name})";
}

class SacdArea {
  const SacdArea({
    required this.tracks,
    required this.encoding,
    required this.audioStartLsn,
    required this.audioEndLsn,
    this.album,
    this.artist,
    this.discNumber,
    this.discTotal,
  });

  final List<SacdTrack> tracks;
  final SacdEncoding encoding;
  final int audioStartLsn;
  final int audioEndLsn;
  final String? album;
  final String? artist;
  final int? discNumber;
  final int? discTotal;

  SacdArea withMaster({String? album, String? artist, int? discNumber, int? discTotal}) => SacdArea(
    tracks: tracks,
    encoding: encoding,
    audioStartLsn: audioStartLsn,
    audioEndLsn: audioEndLsn,
    album: album,
    artist: artist,
    discNumber: discNumber,
    discTotal: discTotal,
  );
}

/// An open image: 2048-byte logical sectors, or 2064-byte physical ones (12-byte header, 4-byte trailer).
class SacdImage {
  SacdImage._(this._source, this._stride, this._offset, this.sectors);

  final ByteSource _source;
  final int _stride;
  final int _offset;
  final int sectors;
  late final SacdArea area;

  Uint8List readSector(int lsn) {
    if (lsn < 0 || lsn >= sectors) throw SacdFormatException("sector $lsn is outside the image");
    final bytes = _source.read(lsn * _stride + _offset, sacdSectorSize);
    if (bytes.length != sacdSectorSize) throw SacdFormatException("sector $lsn is cut off");
    return bytes;
  }

  /// The byte range of the image a read of [lsn] touches (for progressive sources).
  int endOffsetOf(int lsn) => lsn * _stride + _offset + sacdSectorSize;

  void close() => _source.close();

  /// Reads the master table and the stereo area's table.
  static SacdImage open(ByteSource source) {
    var stride = sacdSectorSize;
    var offset = 0;
    String? found;
    for (final (s, o, name) in [(2048, 0, "logical"), (2064, 12, "physical")]) {
      for (final lsn in _masterTocLsn) {
        final sig = source.read(lsn * s + o, 8);
        if (sig.length == 8 && String.fromCharCodes(sig) == "SACDMTOC") {
          if (found != null && found != name) {
            throw SacdFormatException("the image reads as both a 2048 and a 2064-byte dump");
          }
          found = name;
          stride = s;
          offset = o;
          break;
        }
      }
    }
    final sectors = source.length ~/ stride;
    if (sectors <= _masterTocLsn.first) throw SacdFormatException("the image is shorter than its master table");
    final image = SacdImage._(source, stride, offset, sectors);

    Uint8List? master;
    var masterLsn = 0;
    for (final lsn in _masterTocLsn) {
      final s = image.readSector(lsn);
      if (String.fromCharCodes(s, 0, 8) == "SACDMTOC") {
        master = s;
        masterLsn = lsn;
        break;
      }
    }
    if (master == null) throw SacdFormatException("SACDMTOC was not found");
    if (master[8] != 1) throw SacdFormatException("Master TOC version ${master[8]}.${master[9]}");

    Uint8List? toc;
    for (final (primary, backup, size) in [
      (readU32BE(master, 0x40), readU32BE(master, 0x44), readU16BE(master, 0x54)),
      (readU32BE(master, 0x48), readU32BE(master, 0x4c), readU16BE(master, 0x56)),
    ]) {
      if (size == 0 || size > _maxAreaTocSectors) continue;
      for (final start in [primary, backup].where((s) => s != 0)) {
        try {
          final bytes = Uint8List(sacdSectorSize * size);
          for (var i = 0; i < size; i++) {
            bytes.setAll(i * sacdSectorSize, image.readSector(start + i));
          }
          if (String.fromCharCodes(bytes, 0, 8) == "TWOCHTOC") {
            toc = bytes;
            break;
          }
        } on SacdFormatException {
          continue;
        }
      }
      if (toc != null) break;
    }
    if (toc == null) throw SacdFormatException("the stereo area (TWOCHTOC) was not found");

    var area = parseSacdArea(toc, sectors);
    final setSize = readU16BE(master, 0x10);
    final sequence = readU16BE(master, 0x12);
    String? album;
    String? artist;
    if (master[0x80] != 0 && masterLsn + 1 < sectors) {
      final text = image.readSector(masterLsn + 1);
      if (String.fromCharCodes(text, 0, 8) == "SACDText") {
        final charset = master[0x8a];
        album = _masterString(text, 0x10, charset);
        artist = _masterString(text, 0x12, charset);
      }
    }
    final valid = setSize > 0 && sequence > 0 && sequence <= setSize;
    area = area.withMaster(
      album: album,
      artist: artist,
      discNumber: valid ? sequence : null,
      discTotal: valid ? setSize : null,
    );
    image.area = area;
    return image;
  }
}

String? _masterString(Uint8List text, int at, int charset) {
  final start = readU16BE(text, at);
  if (start == 0 || start >= text.length) return null;
  var end = start;
  while (end < text.length && text[end] != 0) {
    end++;
  }
  return _decode(Uint8List.sublistView(text, start, end), charset);
}

/// Disc text. Only the Latin character sets are read (1: ASCII, 2: ISO 8859-1, 7 without escapes); the CJK ones
/// give no string, and the track is named after its number instead of a garbled title.
String? _decode(Uint8List raw, int charset) {
  final String? text = switch (charset & 0x07) {
    1 => raw.every((b) => b < 0x80) ? String.fromCharCodes(raw) : null,
    2 => String.fromCharCodes(raw),
    7 => raw.contains(0x1b) ? null : String.fromCharCodes(raw),
    _ => null,
  };
  final trimmed = text?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

int _timecodeFrames(Uint8List b, int at) => (b[at] * 60 + b[at + 1]) * 75 + b[at + 2];

Uint8List? _findBlock(Uint8List toc, String signature) {
  for (var at = 0; at + 8 <= toc.length; at += sacdSectorSize) {
    if (String.fromCharCodes(toc, at, at + 8) == signature) return Uint8List.sublistView(toc, at);
  }
  return null;
}

(String?, String?) _trackText(Uint8List block, int track, int charset) {
  String? title;
  String? performer;
  final pointerAt = 8 + track * 2;
  if (pointerAt + 2 > block.length) return (null, null);
  final record = readU16BE(block, pointerAt);
  if (record == 0 || record >= block.length) return (null, null);
  final items = block[record];
  var at = record + 4;
  for (var i = 0; i < items; i++) {
    if (at >= block.length) break;
    final kind = block[at];
    at += 2;
    var end = at;
    while (end < block.length && block[end] != 0) {
      end++;
    }
    if (end >= block.length) break;
    final value = _decode(Uint8List.sublistView(block, at, end), charset);
    if (kind == 1) title = value;
    if (kind == 2) performer = value;
    at = end;
    while (at < block.length && block[at] == 0) {
      at++;
    }
  }
  return (title, performer);
}

/// Parses a stereo area table ("TWOCHTOC" and the sectors after it).
SacdArea parseSacdArea(Uint8List toc, int sectors) {
  final channels = toc[0x20];
  if (channels != 2 || toc[0x21] & 0x1f != 0) throw SacdFormatException("$channels channels in the stereo area");
  if (toc[0x14] != 4) throw SacdFormatException("rate code ${toc[0x14]}");
  final encoding = switch (toc[0x15] & 0x0f) {
    0 => SacdEncoding.dst,
    2 || 3 => SacdEncoding.dsd,
    final other => throw SacdFormatException("frame format $other"),
  };
  final trackCount = toc[0x45];
  if (trackCount == 0) throw SacdFormatException("the area declares no tracks");
  final audioStart = readU32BE(toc, 0x48);
  final audioEnd = readU32BE(toc, 0x4c);
  if (audioStart > audioEnd || audioEnd >= sectors) throw SacdFormatException("the audio area falls outside the image");

  final trl1 = _findBlock(toc, "SACDTRL1");
  final trl2 = _findBlock(toc, "SACDTRL2");
  if (trl1 == null) throw SacdFormatException("SACDTRL1 is missing");
  if (trl2 == null) throw SacdFormatException("SACDTRL2 is missing");
  const secondArray = 8 + 255 * 4;

  final textAt = readU16BE(toc, 0x80);
  final charset = toc[0x5a];
  Uint8List? titles;
  if (textAt != 0) {
    final at = textAt * sacdSectorSize;
    if (at + 8 <= toc.length && String.fromCharCodes(toc, at, at + 8) == "SACDTTxt") {
      titles = Uint8List.sublistView(toc, at);
    }
  } else {
    titles = _findBlock(toc, "SACDTTxt");
  }

  final tracks = <SacdTrack>[];
  int? previousStart;
  for (var i = 0; i < trackCount; i++) {
    final startLsn = readU32BE(trl1, 8 + i * 4);
    final lengthLsn = readU32BE(trl1, secondArray + i * 4);
    for (final at in [8 + i * 4, secondArray + i * 4]) {
      if (trl2[at + 1] >= 60 || trl2[at + 2] >= 75) throw SacdFormatException("invalid timecode in track ${i + 1}");
    }
    final end = startLsn + lengthLsn;
    if (lengthLsn == 0 ||
        startLsn < audioStart ||
        end > audioEnd + 1 ||
        (previousStart != null && startLsn <= previousStart)) {
      throw SacdFormatException("track ${i + 1} falls outside the area, or out of order");
    }
    previousStart = startLsn;
    final (title, performer) = titles == null ? (null, null) : _trackText(titles, i, charset);
    tracks.add(
      SacdTrack(
        number: i + 1,
        startLsn: startLsn,
        lengthLsn: lengthLsn,
        startFrame: _timecodeFrames(trl2, 8 + i * 4),
        durationFrames: _timecodeFrames(trl2, secondArray + i * 4),
        encoding: encoding,
        title: title,
        performer: performer,
      ),
    );
  }
  return SacdArea(tracks: tracks, encoding: encoding, audioStartLsn: audioStart, audioEndLsn: audioEnd);
}

class SacdPacket {
  const SacdPacket({
    required this.frameStart,
    required this.dataType,
    required this.at,
    required this.length,
    this.timecode,
    this.dstPackets,
    this.dstChannels,
  });

  final bool frameStart;
  final int dataType;
  final int at;
  final int length;
  final int? timecode;
  final int? dstPackets;
  final int? dstChannels;

  bool get isAudio => dataType == _dataTypeAudio;
}

class SacdSectorPackets {
  const SacdSectorPackets(this.dst, this.packets);

  final bool dst;
  final List<SacdPacket> packets;
}

/// Decodes the packing of an audio sector. The packet length has eleven bits (not twelve), and the header plus the
/// packet lengths must add up to 2048 (a DST sector may end in zeros no packet declares).
SacdSectorPackets parseSacdSector(Uint8List sector, int lsn) {
  if (sector.length != sacdSectorSize) throw SacdFormatException("sector $lsn is not 2048 bytes");
  final b0 = sector[0];
  final dst = b0 & 0x01 != 0;
  final packetCount = (b0 >> 5) & 0x07;
  final frameInfoCount = (b0 >> 2) & 0x07;
  final frameInfoSize = dst ? 4 : 3;
  final frameInfoAt = 1 + packetCount * 2;
  final headerLength = frameInfoAt + frameInfoCount * frameInfoSize;
  if (packetCount == 0 || headerLength > sacdSectorSize) throw SacdFormatException("sector $lsn: impossible counts");

  final packets = <SacdPacket>[];
  var at = headerLength;
  var total = headerLength;
  var readFrames = 0;
  for (var k = 0; k < packetCount; k++) {
    final w = readU16BE(sector, 1 + 2 * k);
    final length = w & 0x07ff;
    final frameStart = w & 0x8000 != 0;
    final dataType = (w >> 11) & 0x07;
    int? timecode;
    int? dstPackets;
    int? dstChannels;
    if (frameStart) {
      final info = frameInfoAt + readFrames * frameInfoSize;
      readFrames++;
      if (dataType == _dataTypeAudio) {
        if (info + frameInfoSize > sacdSectorSize) throw SacdFormatException("sector $lsn: frame-info cut off");
        if (sector[info + 1] >= 60 || sector[info + 2] >= 75) {
          throw SacdFormatException("sector $lsn: invalid timecode in frame-info");
        }
        timecode = _timecodeFrames(sector, info);
        if (dst) {
          final flags = sector[info + 3];
          dstPackets = (flags >> 2) & 0x1f;
          dstChannels = switch ((flags & 0x02 != 0, flags & 0x01 != 0)) {
            (true, false) => 6,
            (false, true) => 5,
            _ => 2,
          };
        }
      }
    }
    total += length;
    if (total > sacdSectorSize) throw SacdFormatException("sector $lsn: the packets add up to $total bytes");
    packets.add(
      SacdPacket(
        frameStart: frameStart,
        dataType: dataType,
        at: at,
        length: length,
        timecode: timecode,
        dstPackets: dstPackets,
        dstChannels: dstChannels,
      ),
    );
    at += length;
  }
  if (total != sacdSectorSize) {
    final zeroTail = dst && sector.skip(total).every((b) => b == 0);
    if (!zeroTail) throw SacdFormatException("sector $lsn: the packets add up to $total and not 2048");
  }
  if (readFrames != frameInfoCount) throw SacdFormatException("sector $lsn: frame-info records do not match");
  return SacdSectorPackets(dst, packets);
}

/// The first audio frame starting at or after [lsn] (within 32 sectors), as (sector, timecode).
(int, int)? _firstStartFrom(SacdImage image, int lsn, int endLsn) {
  for (var at = lsn; at < min(lsn + 32, endLsn); at++) {
    final packets = parseSacdSector(image.readSector(at), at);
    for (final p in packets.packets) {
      if (p.isAudio && p.frameStart && p.timecode != null) return (at, p.timecode!);
    }
  }
  return null;
}

/// Binary search for the sector from which the next frame to start is [target] or later.
int _searchFrame(SacdImage image, int startLsn, int endLsn, int target) {
  var low = startLsn;
  var high = endLsn;
  while (low < high) {
    final middle = low + (high - low) ~/ 2;
    final found = _firstStartFrom(image, middle, endLsn);
    if (found != null && found.$2 < target) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// An uncompressed track of the stereo area as DSD (DSD64, two channels, MSB first).
class SacdTrackReader implements DsdSource {
  SacdTrackReader(this.image, this.track) {
    if (track.encoding == SacdEncoding.dst) {
      throw SacdFormatException("track ${track.number} is DST-compressed; this app has no DST decoder");
    }
    _lsn = track.startLsn;
    _endLsn = track.startLsn + track.lengthLsn;
    _framesLeft = track.durationFrames;
  }

  final SacdImage image;
  final SacdTrack track;
  late int _lsn;
  late final int _endLsn;
  late int _framesLeft;
  bool _synced = false;
  final BytesBuilder _pending = BytesBuilder(copy: false);
  Uint8List _carry = Uint8List(0);

  @override
  int get sampleRate => dsd64Rate;
  @override
  int get channels => 2;
  @override
  int get samples => track.durationFrames * (dsd64Rate ~/ sacdFramesPerSecond);

  @override
  int get nextReadEnd => image.endOffsetOf(min(_lsn + 6, _endLsn - 1));

  void _fill() {
    while (_carry.length + _pending.length < sacdStereoFrameBytes && _lsn < _endLsn) {
      final sector = image.readSector(_lsn);
      final packets = parseSacdSector(sector, _lsn);
      if (packets.dst) throw SacdFormatException("sector $_lsn is DST in an uncompressed area");
      for (final p in packets.packets) {
        if (!p.isAudio) continue;
        // A track's first sector starts with the tail of the previous track's last frame.
        if (!_synced && !p.frameStart) continue;
        _synced = true;
        _pending.add(Uint8List.sublistView(sector, p.at, p.at + p.length));
      }
      _lsn++;
    }
  }

  @override
  List<Uint8List>? nextBlock() {
    if (_framesLeft <= 0) return null;
    _fill();
    final all = Uint8List(_carry.length + _pending.length)
      ..setAll(0, _carry)
      ..setAll(_carry.length, _pending.takeBytes());
    if (all.length < sacdStereoFrameBytes) {
      throw SacdFormatException("the image ends $_framesLeft frames before track ${track.number} does");
    }
    _carry = Uint8List.fromList(Uint8List.sublistView(all, sacdStereoFrameBytes));
    _framesLeft--;
    return splitSacdChannels(Uint8List.sublistView(all, 0, sacdStereoFrameBytes));
  }

  @override
  int seek(int sample) {
    final perFrame = dsd64Rate ~/ sacdFramesPerSecond;
    final offset = min(sample ~/ perFrame, track.durationFrames);
    final target = track.startFrame + offset;
    final end = track.startFrame + track.durationFrames;
    final low = _searchFrame(image, track.startLsn, _endLsn, target);
    final found = _firstStartFrom(image, low, _endLsn);
    final landed = found == null ? end : found.$2.clamp(target, end);
    _pending.clear();
    _carry = Uint8List(0);
    _framesLeft = end - landed;
    _lsn = found?.$1 ?? _endLsn;
    _synced = false;
    return (landed - track.startFrame) * perFrame;
  }

  @override
  void close() => image.close();
}

/// Splits an interleaved stereo frame: even bytes are left, odd ones right.
List<Uint8List> splitSacdChannels(Uint8List frame) {
  final half = frame.length ~/ 2;
  final left = Uint8List(half);
  final right = Uint8List(half);
  for (var i = 0; i < half; i++) {
    left[i] = frame[2 * i];
    right[i] = frame[2 * i + 1];
  }
  return [left, right];
}

/// A DST track's compressed frames, located once (a scan of the track's sectors), so they can be served as a
/// DSDIFF-DST file ([dffDstHeader] + one `DSTF` chunk per frame) to a player with a DST decoder.
class SacdDstFrame {
  const SacdDstFrame(this.timecode, this.parts);

  final int timecode;

  /// (sector, offset in sector, length) of each packet of the frame.
  final List<(int, int, int)> parts;

  int get length => parts.fold(0, (sum, p) => sum + p.$3);
}

/// Scans a DST track's sectors for its frames (and only its own: a track's sectors also hold the neighbours'
/// frames at both ends, told apart by their timecodes).
List<SacdDstFrame> scanSacdDstFrames(SacdImage image, SacdTrack track) {
  if (track.encoding != SacdEncoding.dst) throw SacdFormatException("track ${track.number} is not DST");
  final first = track.startFrame;
  final end = track.startFrame + track.durationFrames;
  final frames = <SacdDstFrame>[];
  List<(int, int, int)>? open;
  var missing = 0;
  var openTimecode = 0;
  final lastLsn = min(track.startLsn + track.lengthLsn + 32, image.area.audioEndLsn + 1);
  for (var lsn = track.startLsn; lsn < lastLsn; lsn++) {
    final sector = image.readSector(lsn);
    final packets = parseSacdSector(sector, lsn);
    for (final p in packets.packets) {
      if (!p.isAudio) continue;
      if (p.frameStart) {
        final count = p.dstPackets ?? 0;
        if (count < 1) throw SacdFormatException("sector $lsn: a DST frame spans no packets");
        if (p.dstChannels != 2) throw SacdFormatException("sector $lsn: a frame of the stereo area is not stereo");
        open = [];
        missing = count;
        openTimecode = p.timecode!;
      }
      if (open == null) continue;
      open.add((lsn, p.at, p.length));
      missing--;
      if (missing == 0) {
        if (openTimecode >= first && openTimecode < end) frames.add(SacdDstFrame(openTimecode, open));
        open = null;
      }
    }
    if (frames.length >= track.durationFrames) break;
  }
  if (frames.length < track.durationFrames) {
    throw SacdFormatException("track ${track.number}: ${frames.length} DST frames found of ${track.durationFrames}");
  }
  return frames;
}

/// The bytes before the first `DSTF` chunk of a DSDIFF-DST file: FRM8, FVER, PROP (FS, CHNL, CMPR), DST + FRTE.
/// [framesBytes] is the total size of the `DSTF` chunks that follow (headers and padding included).
Uint8List dffDstHeader({required int frameCount, required int framesBytes, int rate = dsd64Rate}) {
  final b = BytesBuilder();
  void id(String s) => b.add(s.codeUnits);
  void u64(int v) => b.add((ByteData(8)..setUint64(0, v)).buffer.asUint8List());
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());

  const fver = 12 + 4;
  const fs = 12 + 4;
  const chnl = 12 + 2 + 8;
  // CMPR: 'DST ', a pascal string "DST Encoded" (count byte + 11 chars = 12, even).
  const cmpr = 12 + 4 + 12;
  const prop = 12 + 4 + fs + chnl + cmpr;
  const frte = 12 + 6;
  final dst = 12 + frte + framesBytes;
  final form = 4 + fver + prop + dst;

  id("FRM8");
  u64(form);
  id("DSD ");
  id("FVER");
  u64(4);
  u32(0x01050000);
  id("PROP");
  u64(prop - 12);
  id("SND ");
  id("FS  ");
  u64(4);
  u32(rate);
  id("CHNL");
  u64(2 + 8);
  u16(2);
  id("SLFT");
  id("SRGT");
  id("CMPR");
  u64(4 + 12);
  id("DST ");
  b.addByte(11);
  id("DST Encoded");
  id("DST ");
  u64(frte + framesBytes);
  id("FRTE");
  u64(6);
  u32(frameCount);
  u16(sacdFramesPerSecond);
  return b.toBytes();
}

/// A DST track re-wrapped as a DSDIFF-DST byte stream, readable at any offset (for an HTTP range request).
class SacdDstStream {
  /// [frames] from an earlier scan of the same track skips the scan.
  SacdDstStream(this.image, this.track, {List<SacdDstFrame>? scanned})
    : frames = scanned ?? scanSacdDstFrames(image, track) {
    _chunkStarts = List<int>.filled(frames.length + 1, 0);
    var at = 0;
    for (var i = 0; i < frames.length; i++) {
      _chunkStarts[i] = at;
      final len = frames[i].length;
      at += 12 + len + (len & 1);
    }
    _chunkStarts[frames.length] = at;
    header = dffDstHeader(frameCount: frames.length, framesBytes: at);
  }

  final SacdImage image;
  final SacdTrack track;
  final List<SacdDstFrame> frames;
  late final List<int> _chunkStarts;
  late final Uint8List header;

  int get length => header.length + _chunkStarts.last;

  Uint8List _chunk(int i) {
    final frame = frames[i];
    final len = frame.length;
    final out = Uint8List(12 + len + (len & 1));
    out.setAll(0, "DSTF".codeUnits);
    (ByteData.sublistView(out)).setUint64(4, len);
    var at = 12;
    for (final (lsn, offset, length) in frame.parts) {
      out.setAll(at, Uint8List.sublistView(image.readSector(lsn), offset, offset + length));
      at += length;
    }
    return out;
  }

  /// The bytes [start, end).
  Iterable<Uint8List> range(int start, int end) sync* {
    end = min(end, length);
    var position = start;
    if (position < header.length) {
      final h = Uint8List.sublistView(header, position, min(header.length, end));
      yield h;
      position += h.length;
    }
    if (position >= end) return;
    // Binary search for the chunk holding [position].
    final rel = position - header.length;
    var low = 0;
    var high = frames.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_chunkStarts[mid] <= rel) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    for (var i = low; i < frames.length && position < end; i++) {
      final chunk = _chunk(i);
      final from = position - header.length - _chunkStarts[i];
      final to = min(chunk.length, end - header.length - _chunkStarts[i]);
      final part = Uint8List.sublistView(chunk, from, to);
      yield part;
      position += part.length;
    }
  }
}
