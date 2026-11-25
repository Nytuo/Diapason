import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Random access to bytes, from a file or from memory (tests).
///
/// Synchronous on purpose: the DSD readers pull small blocks in a tight loop, and an `await` per 4 KiB block costs
/// more than the read itself.
abstract class ByteSource {
  int get length;

  /// Up to [count] bytes from [offset]; fewer at the end.
  Uint8List read(int offset, int count);

  void close();
}

class FileByteSource implements ByteSource {
  FileByteSource(String path) : _file = File(path).openSync(), _path = path {
    length = _file.lengthSync();
  }

  final RandomAccessFile _file;
  final String _path;

  @override
  late final int length;

  @override
  Uint8List read(int offset, int count) {
    if (offset >= length || count <= 0) return Uint8List(0);
    _file.setPositionSync(offset);
    return _file.readSync(min(count, length - offset));
  }

  @override
  void close() => _file.closeSync();

  @override
  String toString() => "FileByteSource($_path)";
}

class MemoryByteSource implements ByteSource {
  MemoryByteSource(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) {
    if (offset >= bytes.length || count <= 0) return Uint8List(0);
    return Uint8List.sublistView(bytes, offset, min(bytes.length, offset + count));
  }

  @override
  void close() {}
}

int readU16BE(Uint8List b, int at) => (b[at] << 8) | b[at + 1];
int readU32BE(Uint8List b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
int readU64BE(Uint8List b, int at) => (readU32BE(b, at) << 32) | readU32BE(b, at + 4);
int readU16LE(Uint8List b, int at) => b[at] | (b[at + 1] << 8);
int readU32LE(Uint8List b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);
int readU64LE(Uint8List b, int at) => readU32LE(b, at) | (readU32LE(b, at + 4) << 32);
String readId(Uint8List b, int at) => String.fromCharCodes(b, at, at + 4);
