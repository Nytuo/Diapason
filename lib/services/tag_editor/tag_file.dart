import 'dart:io';

import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/formats/file_rewrite.dart';
import 'package:diapason/services/tag_editor/formats/flac_tags.dart';
import 'package:diapason/services/tag_editor/formats/id3v2_tags.dart';
import 'package:diapason/services/tag_editor/formats/mp4_tags.dart';
import 'package:diapason/services/tag_editor/formats/ogg_tags.dart';

enum TagContainer { id3v2, flac, ogg, mp4 }

/// Reads and writes tags of a local audio file, picking the codec from the
/// file's magic bytes (falling back to the extension for raw MP3 streams).
abstract final class TagFile {
  static const supportedExtensions = {
    ".mp3",
    ".flac",
    ".ogg",
    ".oga",
    ".opus",
    ".m4a",
    ".m4b",
    ".mp4",
    ".aac",
    ".alac",
  };

  static Future<TagContainer> detect(File file) async {
    final raf = await file.open();
    try {
      final head = await readRange(raf, 0, 12);
      String ascii(int start, int end) => head.length >= end ? String.fromCharCodes(head.sublist(start, end)) : "";
      if (ascii(0, 4) == "fLaC") return TagContainer.flac;
      if (ascii(0, 4) == "OggS") return TagContainer.ogg;
      if (ascii(4, 8) == "ftyp") return TagContainer.mp4;
      if (ascii(0, 3) == "ID3") {
        // FLAC files sometimes carry a leading ID3v2 tag.
        final total = 10 + syncsafeDecode(head, 6);
        final after = await readRange(raf, total, 4);
        if (after.length == 4 && String.fromCharCodes(after) == "fLaC") return TagContainer.flac;
        return TagContainer.id3v2;
      }
      // MPEG audio frame sync without a tag yet.
      if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return TagContainer.id3v2;
    } finally {
      await raf.close();
    }
    throw UnsupportedTagFormatException("Unsupported audio file: ${file.path}");
  }

  static Future<AudioTags> read(File file) async => switch (await detect(file)) {
    TagContainer.id3v2 => Id3v2Tags.read(file),
    TagContainer.flac => FlacTags.read(file),
    TagContainer.ogg => OggTags.read(file),
    TagContainer.mp4 => Mp4Tags.read(file),
  };

  static Future<void> write(File file, AudioTags tags) async => switch (await detect(file)) {
    TagContainer.id3v2 => Id3v2Tags.write(file, tags),
    TagContainer.flac => FlacTags.write(file, tags),
    TagContainer.ogg => OggTags.write(file, tags),
    TagContainer.mp4 => Mp4Tags.write(file, tags),
  };
}
