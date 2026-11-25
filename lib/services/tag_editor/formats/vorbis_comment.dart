import 'dart:convert';
import 'dart:typed_data';

import 'package:diapason/services/tag_editor/audio_tags.dart';

/// Vorbis comment block (FLAC VORBIS_COMMENT, Ogg Vorbis/Opus comment header),
/// without any packet prefix or framing bit.
///
/// Keys are case-insensitive; entries keep their original order and spelling
/// so unknown keys round-trip untouched.
class VorbisComment {
  VorbisComment({this.vendor = "Diapason", List<MapEntry<String, String>>? entries}) : entries = entries ?? [];

  String vendor;
  final List<MapEntry<String, String>> entries;

  static const pictureKey = "METADATA_BLOCK_PICTURE";

  /// Primary key written for each field, followed by aliases also read (and
  /// removed on write so stale duplicates don't linger).
  static const Map<TagField, List<String>> keys = {
    TagField.title: ["TITLE"],
    TagField.artists: ["ARTIST"],
    TagField.albumArtists: ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"],
    TagField.album: ["ALBUM"],
    TagField.trackNumber: ["TRACKNUMBER"],
    TagField.trackTotal: ["TRACKTOTAL", "TOTALTRACKS"],
    TagField.discNumber: ["DISCNUMBER"],
    TagField.discTotal: ["DISCTOTAL", "TOTALDISCS"],
    TagField.date: ["DATE", "YEAR"],
    TagField.genres: ["GENRE"],
    TagField.composers: ["COMPOSER"],
    TagField.comment: ["COMMENT", "DESCRIPTION"],
    TagField.lyrics: ["LYRICS", "UNSYNCEDLYRICS"],
    TagField.musicBrainzRecordingId: ["MUSICBRAINZ_TRACKID"],
    TagField.musicBrainzReleaseTrackId: ["MUSICBRAINZ_RELEASETRACKID"],
    TagField.musicBrainzReleaseId: ["MUSICBRAINZ_ALBUMID"],
    TagField.musicBrainzReleaseGroupId: ["MUSICBRAINZ_RELEASEGROUPID"],
    TagField.musicBrainzArtistIds: ["MUSICBRAINZ_ARTISTID"],
    TagField.musicBrainzAlbumArtistIds: ["MUSICBRAINZ_ALBUMARTISTID"],
    TagField.replayGainTrackGain: ["REPLAYGAIN_TRACK_GAIN"],
    TagField.replayGainTrackPeak: ["REPLAYGAIN_TRACK_PEAK"],
    TagField.replayGainAlbumGain: ["REPLAYGAIN_ALBUM_GAIN"],
    TagField.replayGainAlbumPeak: ["REPLAYGAIN_ALBUM_PEAK"],
  };

  static VorbisComment parse(Uint8List bytes, [int offset = 0]) {
    final data = ByteData.sublistView(bytes);
    var pos = offset;
    int u32() {
      if (pos + 4 > bytes.length) throw const FormatException("Truncated Vorbis comment");
      final v = data.getUint32(pos, Endian.little);
      pos += 4;
      return v;
    }

    String str() {
      final len = u32();
      if (pos + len > bytes.length) throw const FormatException("Truncated Vorbis comment string");
      final s = utf8.decode(bytes.sublist(pos, pos + len), allowMalformed: true);
      pos += len;
      return s;
    }

    final vendor = str();
    final count = u32();
    final entries = <MapEntry<String, String>>[];
    for (var i = 0; i < count; i++) {
      final raw = str();
      final eq = raw.indexOf("=");
      if (eq <= 0) continue;
      entries.add(MapEntry(raw.substring(0, eq), raw.substring(eq + 1)));
    }
    return VorbisComment(vendor: vendor, entries: entries);
  }

  Uint8List serialize() {
    final out = BytesBuilder(copy: false);
    void u32(int v) => out.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
    void str(String s) {
      final b = utf8.encode(s);
      u32(b.length);
      out.add(b);
    }

    str(vendor);
    u32(entries.length);
    for (final e in entries) {
      str("${e.key}=${e.value}");
    }
    return out.toBytes();
  }

  List<String> valuesOf(String key) =>
      entries.where((e) => e.key.toUpperCase() == key.toUpperCase()).map((e) => e.value).toList();

  void removeKeys(Iterable<String> keys) {
    final upper = keys.map((k) => k.toUpperCase()).toSet();
    entries.removeWhere((e) => upper.contains(e.key.toUpperCase()));
  }

  /// Reads the known fields. Embedded `METADATA_BLOCK_PICTURE` pictures are
  /// decoded too (Ogg); FLAC files keep their pictures in PICTURE blocks.
  AudioTags toTags() {
    final tags = AudioTags();
    for (final MapEntry(key: field, value: names) in keys.entries) {
      for (final name in names) {
        final values = valuesOf(name);
        if (values.isNotEmpty) {
          tags.set(field, values);
          break;
        }
      }
    }
    // "3/12" in TRACKNUMBER/DISCNUMBER is common.
    for (final (numberField, totalField) in [
      (TagField.trackNumber, TagField.trackTotal),
      (TagField.discNumber, TagField.discTotal),
    ]) {
      final (n, total) = parseNumberPair(tags[numberField]);
      if (tags[numberField] != null) tags.setNumber(numberField, n);
      if (tags[totalField] == null && total != null) tags.setNumber(totalField, total);
    }
    for (final encoded in valuesOf(pictureKey)) {
      try {
        tags.pictures.add(FlacPicture.parse(base64.decode(encoded.trim())));
      } catch (_) {
        // A corrupt picture entry is left in place but not shown.
      }
    }
    return tags;
  }

  /// Replaces every known field (and its aliases) with [tags]' values, keeping
  /// all other entries. When [embedPictures] is set (Ogg), pictures are written
  /// as `METADATA_BLOCK_PICTURE` entries.
  void applyTags(AudioTags tags, {required bool embedPictures}) {
    removeKeys(keys.values.expand((k) => k));
    for (final MapEntry(key: field, value: names) in keys.entries) {
      for (final value in tags.all(field)) {
        entries.add(MapEntry(names.first, value));
      }
    }
    if (embedPictures) {
      removeKeys(const [pictureKey]);
      for (final picture in tags.pictures) {
        entries.add(MapEntry(pictureKey, base64.encode(FlacPicture.serialize(picture))));
      }
    }
  }
}

/// FLAC PICTURE block payload, also used base64-encoded in Ogg comments.
abstract final class FlacPicture {
  static TagPicture parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var pos = 0;
    int u32() {
      if (pos + 4 > bytes.length) throw const FormatException("Truncated FLAC picture");
      final v = data.getUint32(pos);
      pos += 4;
      return v;
    }

    Uint8List chunk(int len) {
      if (pos + len > bytes.length) throw const FormatException("Truncated FLAC picture");
      final b = Uint8List.sublistView(bytes, pos, pos + len);
      pos += len;
      return b;
    }

    final type = u32();
    final mime = latin1.decode(chunk(u32()));
    final description = utf8.decode(chunk(u32()), allowMalformed: true);
    final width = u32();
    final height = u32();
    final depth = u32();
    final colors = u32();
    final image = Uint8List.fromList(chunk(u32()));
    return TagPicture(
      data: image,
      mimeType: mime.isEmpty ? TagPicture.sniffMimeType(image) : mime,
      type: type,
      description: description,
      width: width,
      height: height,
      colorDepth: depth,
      indexedColors: colors,
    );
  }

  static Uint8List serialize(TagPicture picture) {
    final out = BytesBuilder(copy: false);
    void u32(int v) => out.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());
    final mime = latin1.encode(picture.mimeType);
    final description = utf8.encode(picture.description);
    u32(picture.type);
    u32(mime.length);
    out.add(mime);
    u32(description.length);
    out.add(description);
    u32(picture.width);
    u32(picture.height);
    u32(picture.colorDepth);
    u32(picture.indexedColors);
    u32(picture.data.length);
    out.add(picture.data);
    return out.toBytes();
  }
}
