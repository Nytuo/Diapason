import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/hifi/dsd/byte_source.dart';
import 'package:diapason/services/hifi/dsd/dop.dart';
import 'package:diapason/services/hifi/dsd/dsd_container.dart';
import 'package:diapason/services/hifi/dsd/dsd_to_pcm.dart';
import 'package:diapason/services/hifi/dsd/sacd.dart';
import 'package:diapason/services/hifi/dsd/virtual_wav.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic files, built byte by byte from the format descriptions.

void _u32le(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
void _u64le(BytesBuilder b, int v) => b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
void _u16be(BytesBuilder b, int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
void _u32be(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
void _u64be(BytesBuilder b, int v) => b.add((ByteData(8)..setUint64(0, v)).buffer.asUint8List());
void _id(BytesBuilder b, String s) => b.add(s.codeUnits);

/// A DSF file whose channel c holds bytes `(c * 16 + i) & 0xff` (LSB-first in the file), [blockSize] per block.
Uint8List buildDsf({int channels = 2, int rate = dsd64Rate, int bytesPerChannel = 10000, int blockSize = 4096}) {
  final blocks = (bytesPerChannel + blockSize - 1) ~/ blockSize;
  final data = BytesBuilder();
  for (var k = 0; k < blocks; k++) {
    for (var c = 0; c < channels; c++) {
      final block = Uint8List(blockSize);
      for (var i = 0; i < blockSize; i++) {
        final n = k * blockSize + i;
        if (n < bytesPerChannel) block[i] = reverseBitsTable((c * 16 + n) & 0xff);
      }
      data.add(block);
    }
  }
  final payload = data.toBytes();
  final b = BytesBuilder();
  _id(b, "DSD ");
  _u64le(b, 28);
  _u64le(b, 28 + 52 + 12 + payload.length);
  _u64le(b, 0);
  _id(b, "fmt ");
  _u64le(b, 52);
  _u32le(b, 1); // version
  _u32le(b, 0); // format: raw
  _u32le(b, channels == 2 ? 2 : 1); // channel type
  _u32le(b, channels);
  _u32le(b, rate);
  _u32le(b, 1); // LSB first
  _u64le(b, bytesPerChannel * 8);
  _u32le(b, blockSize);
  _u32le(b, 0);
  _id(b, "data");
  _u64le(b, 12 + payload.length);
  b.add(payload);
  return b.toBytes();
}

int reverseBitsTable(int b) {
  var r = 0;
  for (var i = 0; i < 8; i++) {
    if (b & (1 << i) != 0) r |= 0x80 >> i;
  }
  return r;
}

Uint8List buildDff({int channels = 2, int rate = dsd64Rate, int bytesPerChannel = 5000, bool dst = false}) {
  final prop = BytesBuilder();
  _id(prop, "SND ");
  _id(prop, "FS  ");
  _u64be(prop, 4);
  _u32be(prop, rate);
  _id(prop, "CHNL");
  _u64be(prop, 2 + 4 * channels);
  _u16be(prop, channels);
  for (var c = 0; c < channels; c++) {
    _id(prop, "C${c.toString().padLeft(3, "0")}");
  }
  _id(prop, "CMPR");
  _u64be(prop, 4 + 14);
  _id(prop, dst ? "DST " : "DSD ");
  prop.addByte(13);
  prop.add("not compressed".codeUnits.sublist(0, 13));
  final propBytes = prop.toBytes();

  final audio = BytesBuilder();
  if (dst) {
    _id(audio, "DST ");
    final frte = BytesBuilder();
    _id(frte, "FRTE");
    _u64be(frte, 6);
    _u32be(frte, 150);
    _u16be(frte, 75);
    final f = frte.toBytes();
    _u64be(audio, f.length);
    audio.add(f);
  } else {
    _id(audio, "DSD ");
    _u64be(audio, bytesPerChannel * channels);
    for (var i = 0; i < bytesPerChannel; i++) {
      for (var c = 0; c < channels; c++) {
        audio.addByte((c * 16 + i) & 0xff);
      }
    }
  }
  final audioBytes = audio.toBytes();

  final body = BytesBuilder();
  _id(body, "DSD ");
  _id(body, "FVER");
  _u64be(body, 4);
  _u32be(body, 0x01050000);
  _id(body, "PROP");
  _u64be(body, propBytes.length);
  body.add(propBytes);
  if (propBytes.length.isOdd) body.addByte(0);
  body.add(audioBytes);
  final bodyBytes = body.toBytes();

  final b = BytesBuilder();
  _id(b, "FRM8");
  _u64be(b, bodyBytes.length);
  b.add(bodyBytes);
  return b.toBytes();
}

/// A tiny logical-sector SACD image: master TOC at 510, the stereo area TOC at 540 (2 sectors: TWOCHTOC + TRL1/2
/// in one, text in the second), audio from 600. Each track holds [framesPerTrack] uncompressed frames; frame f of
/// the area has every byte equal to `f & 0xff`, left and right interleaved.
Uint8List buildSacdIso({int tracks = 2, int framesPerTrack = 3, bool dst = false}) {
  const audioStart = 600;
  final sectors = <int, Uint8List>{};
  Uint8List sector(int lsn) => sectors.putIfAbsent(lsn, () => Uint8List(sacdSectorSize));

  // Audio: each uncompressed frame (9408 bytes) is packed across sectors, one packet per sector, 2048 - header.
  final trackStarts = <int>[];
  final trackLengths = <int>[];
  var lsn = audioStart;
  var frame = 0;
  for (var t = 0; t < tracks; t++) {
    trackStarts.add(lsn);
    final first = lsn;
    final stream = BytesBuilder();
    final starts = <int>[]; // byte offsets where frames start
    for (var f = 0; f < framesPerTrack; f++) {
      starts.add(stream.length);
      stream.add(Uint8List(sacdStereoFrameBytes)..fillRange(0, sacdStereoFrameBytes, (frame + f) & 0xff));
    }
    final bytes = stream.toBytes();
    var at = 0;
    while (at < bytes.length) {
      final s = sector(lsn);
      final startsHere = starts.contains(at);
      // One packet; a frame-info record only if a frame starts at the packet.
      final header = 1 + 2 + (startsHere ? 3 : 0);
      var len = min(sacdSectorSize - header, bytes.length - at);
      // A frame start falling inside this sector's payload: end the packet there, next sector starts it.
      final nextStart = starts.where((x) => x > at).firstOrNull;
      if (nextStart != null && at + len > nextStart) len = nextStart - at;
      // The sector must add up to 2048: pad with a non-audio packet when the audio is short.
      final pad = sacdSectorSize - header - len;
      s[0] = ((pad > 0 ? 2 : 1) << 5) | ((startsHere ? 1 : 0) << 2);
      final w = (startsHere ? 0x8000 : 0) | (2 << 11) | len;
      s[1] = w >> 8;
      s[2] = w & 0xff;
      var h = 3;
      if (pad > 0) {
        // second descriptor shifts the header by two bytes; recompute
        s[0] = (2 << 5) | ((startsHere ? 1 : 0) << 2);
        final header2 = 1 + 4 + (startsHere ? 3 : 0);
        len = min(len, sacdSectorSize - header2);
        final pad2 = sacdSectorSize - header2 - len;
        final w1 = (startsHere ? 0x8000 : 0) | (2 << 11) | len;
        s[1] = w1 >> 8;
        s[2] = w1 & 0xff;
        final w2 = (7 << 11) | pad2; // data type 7: padding
        s[3] = w2 >> 8;
        s[4] = w2 & 0xff;
        h = 5;
      }
      if (startsHere) {
        final tc = (frame + starts.indexOf(at));
        s[h] = tc ~/ 75 ~/ 60;
        s[h + 1] = tc ~/ 75 % 60;
        s[h + 2] = tc % 75;
        h += 3;
      }
      s.setAll(h, Uint8List.sublistView(bytes, at, at + len));
      at += len;
      lsn++;
    }
    trackLengths.add(lsn - first);
    frame += framesPerTrack;
  }
  final audioEnd = lsn - 1;

  // Master TOC.
  final master = sector(510);
  master.setAll(0, "SACDMTOC".codeUnits);
  master[8] = 1;
  ByteData.sublistView(master).setUint16(0x10, 1);
  ByteData.sublistView(master).setUint16(0x12, 1);
  ByteData.sublistView(master).setUint32(0x40, 540);
  ByteData.sublistView(master).setUint32(0x44, 0);
  ByteData.sublistView(master).setUint16(0x54, 3);
  master[0x80] = 1;
  master[0x8a] = 2; // ISO 8859-1
  final text = sector(511);
  text.setAll(0, "SACDText".codeUnits);
  ByteData.sublistView(text).setUint16(0x10, 0x40);
  ByteData.sublistView(text).setUint16(0x12, 0x60);
  text.setAll(0x40, "Synthetic Album".codeUnits);
  text.setAll(0x60, "Test Artist".codeUnits);

  // Area TOC.
  final toc = sector(540);
  toc.setAll(0, "TWOCHTOC".codeUnits);
  toc[0x14] = 4;
  toc[0x15] = dst ? 0 : 2;
  toc[0x20] = 2;
  toc[0x45] = tracks;
  ByteData.sublistView(toc).setUint32(0x48, audioStart);
  ByteData.sublistView(toc).setUint32(0x4c, audioEnd);
  toc[0x5a] = 2;
  final trl1 = sector(541);
  trl1.setAll(0, "SACDTRL1".codeUnits);
  final trl2 = sector(542);
  trl2.setAll(0, "SACDTRL2".codeUnits);
  const second = 8 + 255 * 4;
  for (var t = 0; t < tracks; t++) {
    ByteData.sublistView(trl1).setUint32(8 + t * 4, trackStarts[t]);
    ByteData.sublistView(trl1).setUint32(second + t * 4, trackLengths[t]);
    final startFrame = t * framesPerTrack;
    trl2[8 + t * 4] = startFrame ~/ 75 ~/ 60;
    trl2[8 + t * 4 + 1] = startFrame ~/ 75 % 60;
    trl2[8 + t * 4 + 2] = startFrame % 75;
    trl2[second + t * 4 + 2] = framesPerTrack;
  }

  final total = audioEnd + 10;
  final image = Uint8List(total * sacdSectorSize);
  sectors.forEach((n, s) => image.setAll(n * sacdSectorSize, s));
  return image;
}

void main() {
  group("DSF", () {
    test("the header is read", () {
      final info = parseDsf(MemoryByteSource(buildDsf(bytesPerChannel: 10000)));
      expect(info.container, DsdContainer.dsf);
      expect(info.sampleRate, dsd64Rate);
      expect(info.channels, 2);
      expect(info.samples, 80000);
      expect(info.blockSize, 4096);
      expect(info.lsbFirst, isTrue);
      expect(info.rateName, "DSD64");
    });

    test("blocks come out per channel, MSB first, and the padding of the last block is dropped", () {
      final reader = DsfReader(MemoryByteSource(buildDsf(bytesPerChannel: 10000)));
      final all = [BytesBuilder(), BytesBuilder()];
      List<Uint8List>? block;
      while ((block = reader.nextBlock()) != null) {
        all[0].add(block![0]);
        all[1].add(block[1]);
      }
      final left = all[0].toBytes();
      final right = all[1].toBytes();
      expect(left.length, 10000);
      expect(left[5], 5);
      expect(right[5], 21);
      expect(left[9999], 9999 & 0xff);
    });

    test("a seek lands on a block boundary at or before the target", () {
      final reader = DsfReader(MemoryByteSource(buildDsf(bytesPerChannel: 10000)));
      expect(reader.seek(5000 * 8), 4096 * 8);
      expect(reader.nextBlock()![0][0], 4096 & 0xff);
    });

    test("a rate that is not DSD is refused", () {
      expect(() => parseDsf(MemoryByteSource(buildDsf(rate: 44100))), throwsA(isA<DsdFormatException>()));
    });

    test("tryParseDsd sniffs the container and ignores other files", () {
      expect(tryParseDsd(MemoryByteSource(buildDsf()))?.container, DsdContainer.dsf);
      expect(tryParseDsd(MemoryByteSource(buildDff()))?.container, DsdContainer.dff);
      expect(tryParseDsd(MemoryByteSource(Uint8List.fromList("fLaC0000".codeUnits))), isNull);
    });
  });

  group("DSDIFF", () {
    test("the header is read", () {
      final info = parseDff(MemoryByteSource(buildDff(bytesPerChannel: 5000)));
      expect(info.sampleRate, dsd64Rate);
      expect(info.channels, 2);
      expect(info.samples, 40000);
      expect(info.dst, isFalse);
    });

    test("interleaved bytes are split per channel", () {
      final reader = DffReader(MemoryByteSource(buildDff(bytesPerChannel: 5000)));
      final block = reader.nextBlock()!;
      expect(block[0][3], 3);
      expect(block[1][3], 19);
    });

    test("DST is recognised from CMPR and FRTE, and the plain reader refuses it", () {
      final bytes = buildDff(dst: true);
      final info = parseDff(MemoryByteSource(bytes));
      expect(info.dst, isTrue);
      expect(info.dstFrames, 150);
      expect(info.duration, const Duration(seconds: 2));
      expect(() => DffReader(MemoryByteSource(bytes)), throwsA(isA<DsdFormatException>()));
    });
  });

  group("DSD to PCM", () {
    test("DSD64 becomes 88.2 kHz stereo with the declared frame count", () {
      final reader = DsfReader(MemoryByteSource(buildDsf(bytesPerChannel: 32 * 1000)));
      final converter = DsdPcmConverter(reader);
      expect(converter.sampleRate, 88200);
      expect(converter.totalFrames, 32 * 1000 * 8 ~/ 32);
      var frames = 0;
      Float32List? block;
      while ((block = converter.nextBlock()) != null) {
        frames += block!.length ~/ 2;
      }
      expect(frames, converter.totalFrames);
    });

    test("DSD silence (0x69 idle pattern) converts to near silence", () {
      final source = _ConstantSource(0x69, 32 * 4096);
      final converter = DsdPcmConverter(source);
      converter.nextBlock();
      final block = converter.nextBlock()!;
      for (final s in block) {
        expect(s.abs(), lessThan(0.05));
      }
    });

    test("the WAV header declares 24-bit stereo at the converter's rate", () {
      final header = wavHeader(frames: 100, sampleRate: 88200);
      final d = ByteData.sublistView(header);
      expect(String.fromCharCodes(header, 0, 4), "RIFF");
      expect(d.getUint32(24, Endian.little), 88200);
      expect(d.getUint16(34, Endian.little), 24);
      expect(d.getUint32(40, Endian.little), 600);
    });
  });

  group("DoP", () {
    test("markers alternate and the DSD bytes sit below them, earlier byte first", () {
      final left = Uint8List.fromList([0x11, 0x22, 0x33, 0x44]);
      final right = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);
      final out = Uint8List(12);
      encodeDop(left, right, 2, 0, out);
      expect(out.sublist(0, 6), [0x22, 0x11, dopMarkerA, 0xBB, 0xAA, dopMarkerA]);
      expect(out.sublist(6, 12), [0x44, 0x33, dopMarkerB, 0xDD, 0xCC, dopMarkerB]);
    });

    test("DSD64 is carried at 176.4 kHz, every DSD byte untouched", () {
      final reader = DsfReader(MemoryByteSource(buildDsf(bytesPerChannel: 10000)));
      final encoder = DopEncoder(reader);
      expect(encoder.sampleRate, 176400);
      expect(encoder.totalFrames, 5000);
      final bytes = BytesBuilder();
      Uint8List? b;
      while ((b = encoder.nextBytes()) != null) {
        bytes.add(b!);
      }
      final all = bytes.toBytes();
      expect(all.length, 5000 * 6);
      // frame 7: left bytes 14 and 15
      expect(all[7 * 6 + 1], 14);
      expect(all[7 * 6], 15);
      expect(all[7 * 6 + 2], dopMarkerB);
    });

    test("after a seek the marker still follows the absolute frame", () {
      final reader = DsfReader(MemoryByteSource(buildDsf(bytesPerChannel: 10000)));
      final encoder = DopEncoder(reader)..seekToFrame(2049);
      final first = encoder.nextBytes()!;
      expect(first[2], dopMarkerB);
      expect(first[1], (2049 * 2) & 0xff);
    });

    test("the virtual WAV range serves the exact bytes asked for", () async {
      final producer = DopWavProducer(DsfReader(MemoryByteSource(buildDsf(bytesPerChannel: 10000))));
      expect(producer.byteLength, 44 + 5000 * 6);
      final whole = await _collect(virtualWavRange(producer, 0, producer.byteLength));
      expect(whole.length, producer.byteLength);
      final producer2 = DopWavProducer(DsfReader(MemoryByteSource(buildDsf(bytesPerChannel: 10000))));
      final part = await _collect(virtualWavRange(producer2, 1001, 20003));
      expect(part, whole.sublist(1001, 20003));
    });
  });

  group("SACD", () {
    test("the master and stereo area tables are read", () {
      final image = SacdImage.open(MemoryByteSource(buildSacdIso(tracks: 2, framesPerTrack: 3)));
      final area = image.area;
      expect(area.album, "Synthetic Album");
      expect(area.artist, "Test Artist");
      expect(area.discNumber, 1);
      expect(area.tracks, hasLength(2));
      expect(area.tracks[0].durationFrames, 3);
      expect(area.tracks[1].startFrame, 3);
      expect(area.encoding, SacdEncoding.dsd);
    });

    test("a track is read frame by frame and split into its channels", () {
      final image = SacdImage.open(MemoryByteSource(buildSacdIso(tracks: 2, framesPerTrack: 3)));
      final reader = SacdTrackReader(image, image.area.tracks[1]);
      final values = <int>[];
      List<Uint8List>? block;
      while ((block = reader.nextBlock()) != null) {
        expect(block![0].length, sacdStereoFrameBytes ~/ 2);
        values.add(block[0][0]);
      }
      expect(values, [3, 4, 5]);
    });

    test("a seek finds the frame by its timecode", () {
      final image = SacdImage.open(MemoryByteSource(buildSacdIso(tracks: 1, framesPerTrack: 5)));
      final reader = SacdTrackReader(image, image.area.tracks[0]);
      final landed = reader.seek(2 * (dsd64Rate ~/ 75));
      expect(landed, 2 * (dsd64Rate ~/ 75));
      expect(reader.nextBlock()![0][0], 2);
    });

    test("a file without SACDMTOC is refused", () {
      expect(() => SacdImage.open(MemoryByteSource(Uint8List(600 * 2048))), throwsA(isA<SacdFormatException>()));
    });

    test("DST tracks are listed but not read as plain DSD", () {
      final image = SacdImage.open(MemoryByteSource(buildSacdIso(dst: true)));
      expect(image.area.encoding, SacdEncoding.dst);
      expect(() => SacdTrackReader(image, image.area.tracks[0]), throwsA(isA<SacdFormatException>()));
    });

    test("a DST track's frames are found by timecode and re-wrapped as DSDIFF-DST", () {
      final bytes = buildSacdIso(tracks: 2, framesPerTrack: 3, dst: true);
      // Turn the audio sectors into DST sectors: one 500-byte frame each, frame value = timecode.
      for (var f = 0; f < 6; f++) {
        final at = (600 + f) * sacdSectorSize;
        final s = Uint8List(sacdSectorSize);
        s[0] = (1 << 5) | (1 << 2) | 1;
        final w = 0x8000 | (2 << 11) | 500;
        s[1] = w >> 8;
        s[2] = w & 0xff;
        s[5] = f; // timecode 0:00:f
        s[6] = 1 << 2; // spans one packet, stereo
        s.fillRange(7, 507, 0x40 + f);
        bytes.setAll(at, s);
      }
      // Track 1 = sectors 600-602, track 2 = 603-605.
      final toc = 541 * sacdSectorSize;
      ByteData.sublistView(bytes).setUint32(toc + 8, 600);
      ByteData.sublistView(bytes).setUint32(toc + 12, 603);
      ByteData.sublistView(bytes).setUint32(toc + 8 + 255 * 4, 3);
      ByteData.sublistView(bytes).setUint32(toc + 12 + 255 * 4, 3);
      ByteData.sublistView(bytes).setUint32(540 * sacdSectorSize + 0x4c, 605);
      final image = SacdImage.open(MemoryByteSource(bytes));
      final stream = SacdDstStream(image, image.area.tracks[1]);
      expect(stream.frames.map((f) => f.timecode), [3, 4, 5]);
      final all = BytesBuilder();
      for (final part in stream.range(0, stream.length)) {
        all.add(part);
      }
      final file = all.toBytes();
      expect(file.length, stream.length);
      final info = parseDff(MemoryByteSource(file));
      expect(info.dst, isTrue);
      expect(info.dstFrames, 3);
      final firstChunk = stream.header.length;
      expect(String.fromCharCodes(file, firstChunk, firstChunk + 4), "DSTF");
      expect(file[firstChunk + 12], 0x43);
      final tail = BytesBuilder();
      for (final part in stream.range(firstChunk + 12 + 500 + 5, stream.length)) {
        tail.add(part);
      }
      expect(tail.toBytes(), file.sublist(firstChunk + 12 + 500 + 5));
    });

    test("a sector whose packets do not add up to 2048 is refused", () {
      final s = Uint8List(2048);
      s[0] = (1 << 5);
      s[1] = (2 << 11 | 100) >> 8;
      s[2] = (2 << 11 | 100) & 0xff;
      expect(() => parseSacdSector(s, 1), throwsA(isA<SacdFormatException>()));
    });

    test("the DSDIFF-DST wrapper header is a well-formed FRM8", () {
      final header = dffDstHeader(frameCount: 75, framesBytes: 1000);
      final info = parseDff(MemoryByteSource(Uint8List.fromList([...header, ...Uint8List(1000)])));
      expect(info.dst, isTrue);
      expect(info.dstFrames, 75);
      expect(info.duration, const Duration(seconds: 1));
    });
  });
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final b = BytesBuilder();
  await for (final c in stream) {
    b.add(c);
  }
  return b.toBytes();
}

class _ConstantSource implements DsdSource {
  _ConstantSource(this.value, this.bytes);

  final int value;
  final int bytes;
  int _position = 0;

  @override
  int get sampleRate => dsd64Rate;
  @override
  int get channels => 2;
  @override
  int get samples => bytes * 8;
  @override
  int get nextReadEnd => 0;
  @override
  List<Uint8List>? nextBlock() {
    if (_position >= bytes) return null;
    final n = min(4096, bytes - _position);
    _position += n;
    return [Uint8List(n)..fillRange(0, n, value), Uint8List(n)..fillRange(0, n, value)];
  }

  @override
  int seek(int sample) => _position = sample ~/ 8 * 8 ~/ 8;
  @override
  void close() {}
}
