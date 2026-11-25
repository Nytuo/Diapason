import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/hifi/dsd/byte_source.dart';

/// DSD64: 64 × 44.1 kHz, one bit per sample.
const int dsd64Rate = 2822400;

class DsdFormatException implements Exception {
  DsdFormatException(this.message);

  final String message;

  @override
  String toString() => "DsdFormatException: $message";
}

enum DsdContainer { dsf, dff }

/// Whether [rate] is a DSD rate this app knows (DSD64 to DSD1024, 44.1 kHz family only).
bool isSupportedDsdRate(int rate) {
  for (var m = 64; m <= 1024; m *= 2) {
    if (rate == 44100 * m) return true;
  }
  return false;
}

/// "DSD64", "DSD128"… for a DSD bit rate.
String dsdRateName(int rate) => "DSD${rate ~/ 44100}";

/// What a DSF or DSDIFF header says.
class DsdInfo {
  const DsdInfo({
    required this.container,
    required this.sampleRate,
    required this.channels,
    required this.samples,
    required this.dataOffset,
    required this.dataLength,
    this.dst = false,
    this.blockSize = 0,
    this.lsbFirst = false,
    this.metadataOffset = 0,
    this.dstFrames = 0,
    this.dstFrameRate = 0,
  });

  final DsdContainer container;

  /// One-bit samples per second, per channel (2 822 400 for DSD64).
  final int sampleRate;
  final int channels;

  /// Samples (bits) per channel.
  final int samples;

  /// Where the audio data starts, and how many bytes it has (all channels together).
  final int dataOffset;
  final int dataLength;

  /// DSDIFF compressed with DST (lossless DSD compression used on SACDs).
  final bool dst;

  /// DSF: bytes per channel block (4096), and the bit order inside a byte.
  final int blockSize;
  final bool lsbFirst;

  /// DSF: offset of the ID3v2 tag, 0 when there is none.
  final int metadataOffset;

  /// DSDIFF-DST: frame count and frames per second (75).
  final int dstFrames;
  final int dstFrameRate;

  Duration get duration => Duration(microseconds: samples * 1000000 ~/ sampleRate);

  String get rateName => dsdRateName(sampleRate);

  @override
  String toString() => "DsdInfo(${container.name}, $rateName, $channels ch, $samples samples${dst ? ", DST" : ""})";
}

/// Reads the header of a DSF file (Sony's container).
///
/// Layout: a `DSD ` chunk (28 bytes, with the pointer to the ID3v2 tag), a `fmt ` chunk (52 bytes or more), then
/// `data`. Samples come in blocks of [DsdInfo.blockSize] bytes per channel, one channel after the other; the last
/// block is padded, so the valid length comes from the sample count. `bits per sample` gives the bit order:
/// 1 = earliest bit in the least significant position (the usual case), 8 = most significant first.
DsdInfo parseDsf(ByteSource source) {
  final head = source.read(0, 28);
  if (head.length < 28 || readId(head, 0) != "DSD ") throw DsdFormatException("not a DSF file (no DSD chunk)");
  if (readU64LE(head, 4) != 28) throw DsdFormatException("the DSD chunk is not 28 bytes");
  final metadataOffset = readU64LE(head, 20);

  final fmt = source.read(28, 52);
  if (fmt.length < 52 || readId(fmt, 0) != "fmt ") throw DsdFormatException("the fmt chunk is missing");
  final fmtSize = readU64LE(fmt, 4);
  if (fmtSize < 52) throw DsdFormatException("the fmt chunk is $fmtSize bytes, the minimum is 52");
  final version = readU32LE(fmt, 12);
  final formatId = readU32LE(fmt, 16);
  final channels = readU32LE(fmt, 24);
  final rate = readU32LE(fmt, 28);
  final bitsPerSample = readU32LE(fmt, 32);
  final samples = readU64LE(fmt, 36);
  final blockSize = readU32LE(fmt, 44);

  if (version != 1 || formatId != 0) throw DsdFormatException("DSF version $version, format $formatId");
  if (channels < 1 || channels > 6) throw DsdFormatException("$channels channels");
  if (!isSupportedDsdRate(rate)) throw DsdFormatException("unsupported DSD rate $rate Hz");
  final lsbFirst = switch (bitsPerSample) {
    1 => true,
    8 => false,
    _ => throw DsdFormatException("bits per sample $bitsPerSample"),
  };
  if (blockSize == 0 || blockSize > (1 << 20)) throw DsdFormatException("a block of $blockSize bytes");

  final dataHeaderAt = 28 + fmtSize;
  final dataHead = source.read(dataHeaderAt, 12);
  if (dataHead.length < 12 || readId(dataHead, 0) != "data") throw DsdFormatException("the data chunk is missing");
  final dataLength = readU64LE(dataHead, 4) - 12;
  return DsdInfo(
    container: DsdContainer.dsf,
    sampleRate: rate,
    channels: channels,
    samples: samples,
    dataOffset: dataHeaderAt + 12,
    dataLength: dataLength,
    blockSize: blockSize,
    lsbFirst: lsbFirst,
    metadataOffset: metadataOffset,
  );
}

/// Reads the header of a DSDIFF (.dff) file (Philips' container).
///
/// Big-endian chunks padded to an even length: `FRM8` of form `DSD `, holding `FVER`, a `PROP` chunk of type `SND `
/// (`FS  ` rate, `CHNL` channels, `CMPR` compression) and the audio: a `DSD ` chunk (one byte of each channel in
/// turn, most significant bit first) or a `DST ` chunk (`FRTE` then one `DSTF` chunk per compressed frame).
DsdInfo parseDff(ByteSource source) {
  final head = source.read(0, 16);
  if (head.length < 16 || readId(head, 0) != "FRM8") throw DsdFormatException("not a DSDIFF file (no FRM8 chunk)");
  if (readId(head, 12) != "DSD ") throw DsdFormatException("the FRM8 chunk does not hold DSD");
  final formEnd = min(12 + readU64BE(head, 4), source.length);

  int? rate;
  int? channels;
  var compression = "DSD ";
  int? dataOffset;
  int? dataLength;
  var dstFrames = 0;
  var dstFrameRate = 0;

  var at = 16;
  while (at + 12 <= formEnd) {
    final chunk = source.read(at, 12);
    final id = readId(chunk, 0);
    final len = readU64BE(chunk, 4);
    final start = at + 12;
    final end = start + len;
    if (len < 0 || (end > formEnd && id != "DSD " && id != "DST ")) {
      throw DsdFormatException("chunk '$id' runs past the end of the file");
    }
    switch (id) {
      case "PROP":
        final type = source.read(start, 4);
        if (type.length < 4 || readId(type, 0) != "SND ") throw DsdFormatException("the PROP chunk is not of sound");
        var sub = start + 4;
        while (sub + 12 <= end) {
          final subHead = source.read(sub, 12);
          final subId = readId(subHead, 0);
          final subLen = readU64BE(subHead, 4);
          final body = source.read(sub + 12, min(subLen, 16));
          switch (subId) {
            case "FS  ":
              if (body.length < 4) throw DsdFormatException("the FS chunk is too short");
              rate = readU32BE(body, 0);
            case "CHNL":
              if (body.length < 2) throw DsdFormatException("the CHNL chunk is too short");
              channels = readU16BE(body, 0);
            case "CMPR":
              if (body.length < 4) throw DsdFormatException("the CMPR chunk is too short");
              compression = readId(body, 0);
          }
          sub += 12 + subLen + (subLen & 1);
        }
      case "DSD ":
        dataOffset = start;
        dataLength = min(len, source.length - start);
      case "DST ":
        dataOffset = start;
        dataLength = min(len, source.length - start);
        final frte = source.read(start, 18);
        if (frte.length >= 18 && readId(frte, 0) == "FRTE") {
          dstFrames = readU32BE(frte, 12);
          dstFrameRate = readU16BE(frte, 16);
        }
    }
    if (dataOffset != null && rate != null && channels != null && end > source.length) break;
    at = end + (len & 1);
  }

  if (rate == null) throw DsdFormatException("the FS chunk is missing");
  if (channels == null) throw DsdFormatException("the CHNL chunk is missing");
  if (dataOffset == null || dataLength == null) throw DsdFormatException("the audio chunk is missing");
  if (!isSupportedDsdRate(rate)) throw DsdFormatException("unsupported DSD rate $rate Hz");
  if (channels < 1 || channels > 6) throw DsdFormatException("$channels channels");
  final dst = switch (compression) {
    "DSD " => false,
    "DST " => true,
    _ => throw DsdFormatException("DSDIFF compression '${compression.trim()}'"),
  };

  final int samples;
  if (dst) {
    if (dstFrameRate == 0) throw DsdFormatException("the DST chunk has no FRTE frame count");
    samples = dstFrames * rate ~/ dstFrameRate;
  } else {
    final whole = dataLength - dataLength % channels;
    samples = whole ~/ channels * 8;
  }
  return DsdInfo(
    container: DsdContainer.dff,
    sampleRate: rate,
    channels: channels,
    samples: samples,
    dataOffset: dataOffset,
    dataLength: dataLength,
    dst: dst,
    dstFrames: dstFrames,
    dstFrameRate: dstFrameRate,
  );
}

/// Sniffs the container from the first bytes.
DsdInfo? tryParseDsd(ByteSource source) {
  final magic = source.read(0, 4);
  if (magic.length < 4) return null;
  try {
    return switch (readId(magic, 0)) {
      "DSD " => parseDsf(source),
      "FRM8" => parseDff(source),
      _ => null,
    };
  } on DsdFormatException {
    return null;
  }
}

/// Uncompressed DSD, handed out per channel, most significant bit first.
abstract class DsdSource {
  int get sampleRate;
  int get channels;

  /// Samples (bits) per channel.
  int get samples;

  /// The next block, one list of bytes per channel; `null` at the end.
  List<Uint8List>? nextBlock();

  /// Moves to [sample] or the closest earlier position the container allows, and returns where it landed.
  int seek(int sample);

  /// The byte offset in the underlying file up to which the next [nextBlock] reads (lets a progressive download
  /// wait for those bytes first).
  int get nextReadEnd;

  void close();
}

final Uint8List _reverseBits = Uint8List.fromList(
  List.generate(256, (b) {
    var r = 0;
    for (var i = 0; i < 8; i++) {
      if (b & (1 << i) != 0) r |= 0x80 >> i;
    }
    return r;
  }),
);

/// Reverses the bit order of every byte, in place.
void reverseBitsInPlace(Uint8List bytes) {
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = _reverseBits[bytes[i]];
  }
}

class DsfReader implements DsdSource {
  DsfReader(this._source, {DsdInfo? info}) : info = info ?? parseDsf(_source) {
    _bytesPerChannel = (this.info.samples + 7) ~/ 8;
    _position = 0;
  }

  final ByteSource _source;
  final DsdInfo info;
  late final int _bytesPerChannel;

  /// Byte position inside each channel, always a multiple of the block size.
  late int _position;

  @override
  int get sampleRate => info.sampleRate;
  @override
  int get channels => info.channels;
  @override
  int get samples => info.samples;

  @override
  List<Uint8List>? nextBlock() {
    if (_position >= _bytesPerChannel) return null;
    final block = info.blockSize;
    final valid = min(block, _bytesPerChannel - _position);
    final groupOffset = info.dataOffset + (_position ~/ block) * block * info.channels;
    final group = _source.read(groupOffset, block * info.channels);
    if (group.length < block * (info.channels - 1) + valid) {
      throw DsdFormatException("the file ends before its declared samples");
    }
    final out = <Uint8List>[];
    for (var c = 0; c < info.channels; c++) {
      final channel = Uint8List.fromList(Uint8List.sublistView(group, c * block, c * block + valid));
      if (info.lsbFirst) reverseBitsInPlace(channel);
      out.add(channel);
    }
    _position += valid;
    return out;
  }

  @override
  int get nextReadEnd {
    final block = info.blockSize;
    return info.dataOffset + (_position ~/ block + 1) * block * info.channels;
  }

  @override
  int seek(int sample) {
    final byte = min(sample ~/ 8, _bytesPerChannel);
    _position = byte ~/ info.blockSize * info.blockSize;
    return _position * 8;
  }

  @override
  void close() => _source.close();
}

class DffReader implements DsdSource {
  DffReader(this._source, {DsdInfo? info}) : info = info ?? parseDff(_source) {
    if (this.info.dst) throw DsdFormatException("DST-compressed DSDIFF needs a DST decoder");
    _end = this.info.dataLength - this.info.dataLength % this.info.channels;
  }

  static const _blockPerChannel = 4096;

  final ByteSource _source;
  final DsdInfo info;
  late final int _end;
  int _position = 0;

  @override
  int get sampleRate => info.sampleRate;
  @override
  int get channels => info.channels;
  @override
  int get samples => info.samples;

  @override
  List<Uint8List>? nextBlock() {
    final take = min(_blockPerChannel * info.channels, _end - _position);
    if (take <= 0) return null;
    final interleaved = _source.read(info.dataOffset + _position, take);
    if (interleaved.length < take) throw DsdFormatException("the file ends before its declared samples");
    _position += take;
    final n = info.channels;
    final perChannel = take ~/ n;
    final out = List.generate(n, (_) => Uint8List(perChannel));
    for (var i = 0, k = 0; i < perChannel; i++) {
      for (var c = 0; c < n; c++) {
        out[c][i] = interleaved[k++];
      }
    }
    return out;
  }

  @override
  int get nextReadEnd => info.dataOffset + min(_end, _position + _blockPerChannel * info.channels);

  @override
  int seek(int sample) {
    final byte = min(sample ~/ 8, _end ~/ info.channels);
    _position = byte * info.channels;
    return byte * 8;
  }

  @override
  void close() => _source.close();
}

/// Opens the uncompressed DSD in [source], DSF or DSDIFF.
DsdSource openDsd(ByteSource source) {
  final magic = source.read(0, 4);
  if (magic.length == 4 && readId(magic, 0) == "DSD ") return DsfReader(source);
  if (magic.length == 4 && readId(magic, 0) == "FRM8") return DffReader(source);
  throw DsdFormatException("not a DSF or DSDIFF file");
}
