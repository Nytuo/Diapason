import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/formats/file_rewrite.dart';
import 'package:diapason/services/tag_editor/formats/vorbis_comment.dart';

/// FLAC metadata blocks: VORBIS_COMMENT (4) carries text tags, PICTURE (6)
/// carries artwork. STREAMINFO, SEEKTABLE, CUESHEET, APPLICATION blocks and
/// any leading ID3v2 tag are kept byte for byte.
abstract final class FlacTags {
  static const _streamInfo = 0;
  static const _padding = 1;
  static const _vorbisComment = 4;
  static const _picture = 6;
  static const _defaultPadding = 4096;

  static Future<AudioTags> read(File file) async {
    final layout = await _readLayout(file);
    final commentBlock = layout.blocks.where((b) => b.type == _vorbisComment).firstOrNull;
    final tags = commentBlock == null ? AudioTags() : VorbisComment.parse(commentBlock.data).toTags();
    for (final block in layout.blocks.where((b) => b.type == _picture)) {
      try {
        tags.pictures.add(FlacPicture.parse(block.data));
      } catch (_) {}
    }
    return tags;
  }

  static Future<void> write(File file, AudioTags tags) async {
    final layout = await _readLayout(file);
    final oldComment = layout.blocks.where((b) => b.type == _vorbisComment).firstOrNull;
    final comment = oldComment == null ? VorbisComment() : VorbisComment.parse(oldComment.data);
    comment.applyTags(tags, embedPictures: false);

    final kept = layout.blocks.where((b) => b.type != _vorbisComment && b.type != _picture && b.type != _padding);
    final newBlocks = <_Block>[
      ...kept.where((b) => b.type == _streamInfo),
      ...kept.where((b) => b.type != _streamInfo),
      _Block(_vorbisComment, comment.serialize()),
      for (final p in tags.pictures) _Block(_picture, FlacPicture.serialize(p)),
    ];
    for (final b in newBlocks) {
      if (b.data.length >= 1 << 24) throw const UnsupportedTagFormatException("FLAC metadata block over 16 MiB");
    }

    final metadataSize = newBlocks.fold<int>(0, (sum, b) => sum + 4 + b.data.length);
    final available = layout.audioOffset - layout.flacOffset - 4;
    // Reuse the old space when the new blocks fit with a padding block (4-byte
    // header) so the audio doesn't need to move.
    final fitsInPlace = metadataSize + 4 <= available;
    final paddingSize = fitsInPlace ? available - metadataSize - 4 : _defaultPadding;

    final out = BytesBuilder(copy: false)..add(const [0x66, 0x4C, 0x61, 0x43]);
    for (final b in newBlocks) {
      out.add(_header(b.type, b.data.length, last: false));
      out.add(b.data);
    }
    out.add(_header(_padding, paddingSize, last: true));
    out.add(Uint8List(paddingSize));
    final head = out.toBytes();

    if (fitsInPlace && layout.flacOffset == 0) {
      await overwriteHead(file, head);
    } else {
      await rewriteFile(file, [
        if (layout.flacOffset > 0) SourceRange(0, layout.flacOffset),
        BytesSegment(head),
        SourceRange(layout.audioOffset),
      ]);
    }
  }

  static List<int> _header(int type, int length, {required bool last}) => [
    (last ? 0x80 : 0) | type,
    (length >> 16) & 0xFF,
    (length >> 8) & 0xFF,
    length & 0xFF,
  ];

  static Future<_Layout> _readLayout(File file) async {
    final raf = await file.open();
    try {
      var offset = 0;
      final head = await readRange(raf, 0, 10);
      // Some encoders prepend an ID3v2 tag; skip it.
      if (head.length == 10 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
        offset = 10 + syncsafeDecode(head, 6) + ((head[5] & 0x10) != 0 ? 10 : 0);
      }
      final magic = await readRange(raf, offset, 4);
      if (magic.length < 4 || String.fromCharCodes(magic) != "fLaC") {
        throw const UnsupportedTagFormatException("Not a FLAC file");
      }
      final flacOffset = offset;
      var pos = offset + 4;
      final blocks = <_Block>[];
      final length = await raf.length();
      while (true) {
        final h = await readRange(raf, pos, 4);
        if (h.length < 4) throw const FormatException("Truncated FLAC metadata");
        final last = (h[0] & 0x80) != 0;
        final type = h[0] & 0x7F;
        final size = (h[1] << 16) | (h[2] << 8) | h[3];
        if (pos + 4 + size > length) throw const FormatException("FLAC metadata block extends beyond the file");
        // Padding content is never needed.
        final data = type == _padding ? Uint8List(0) : await readRange(raf, pos + 4, size);
        blocks.add(_Block(type, data));
        pos += 4 + size;
        if (last) break;
      }
      return _Layout(flacOffset, pos, blocks);
    } finally {
      await raf.close();
    }
  }
}

class _Block {
  _Block(this.type, this.data);
  final int type;
  final Uint8List data;
}

class _Layout {
  _Layout(this.flacOffset, this.audioOffset, this.blocks);
  final int flacOffset;
  final int audioOffset;
  final List<_Block> blocks;
}
