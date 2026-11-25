import 'dart:io';
import 'dart:typed_data';

/// A piece of the rewritten file: either new bytes, or a byte range copied
/// from the original file (streamed, so large audio payloads never sit in memory).
sealed class FileSegment {
  const FileSegment();
}

class BytesSegment extends FileSegment {
  const BytesSegment(this.bytes);
  final List<int> bytes;
}

class SourceRange extends FileSegment {
  const SourceRange(this.start, [this.end]);
  final int start;

  /// Exclusive; null means end of file.
  final int? end;
}

/// Bytes produced lazily while writing (e.g. renumbered Ogg pages).
class StreamSegment extends FileSegment {
  const StreamSegment(this.open);
  final Stream<List<int>> Function() open;
}

/// Rewrites [file] from [segments] into a temporary sibling, then atomically
/// renames it over the original. The original is untouched on failure.
Future<void> rewriteFile(File file, List<FileSegment> segments) async {
  final temp = File("${file.path}.diapason-tags.tmp");
  final sink = temp.openWrite();
  try {
    for (final segment in segments) {
      switch (segment) {
        case BytesSegment(:final bytes):
          sink.add(bytes);
        case SourceRange(:final start, :final end):
          if (end != null && end <= start) continue;
          await sink.addStream(file.openRead(start, end));
        case StreamSegment(:final open):
          await sink.addStream(open());
      }
    }
    await sink.flush();
    await sink.close();
    await temp.rename(file.path);
  } catch (_) {
    try {
      await sink.close();
    } catch (_) {}
    if (await temp.exists()) await temp.delete();
    rethrow;
  }
}

/// Overwrites the first bytes of [file] in place (used when a new tag fits in
/// the space of the old one, padding included).
Future<void> overwriteHead(File file, Uint8List bytes) async {
  final raf = await file.open(mode: FileMode.append);
  try {
    await raf.setPosition(0);
    await raf.writeFrom(bytes);
    await raf.flush();
  } finally {
    await raf.close();
  }
}

/// Reads [length] bytes at [offset] (fewer at end of file).
Future<Uint8List> readRange(RandomAccessFile raf, int offset, int length) async {
  await raf.setPosition(offset);
  return raf.read(length);
}

int syncsafeDecode(List<int> b, [int offset = 0]) =>
    ((b[offset] & 0x7F) << 21) |
    ((b[offset + 1] & 0x7F) << 14) |
    ((b[offset + 2] & 0x7F) << 7) |
    (b[offset + 3] & 0x7F);

List<int> syncsafeEncode(int value) {
  if (value >= 1 << 28) throw ArgumentError("Value too large for a syncsafe integer: $value");
  return [(value >> 21) & 0x7F, (value >> 14) & 0x7F, (value >> 7) & 0x7F, value & 0x7F];
}
