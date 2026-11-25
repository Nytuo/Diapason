import 'dart:typed_data';

import 'package:collection/collection.dart';

/// The tag fields Diapason's tag editor understands, independent of the
/// container format. Every format codec maps these to its own frames/atoms/keys
/// and leaves everything else in the file untouched.
enum TagField {
  title,
  artists,
  albumArtists,
  album,
  trackNumber,
  trackTotal,
  discNumber,
  discTotal,
  date,
  genres,
  composers,
  comment,
  lyrics,
  musicBrainzRecordingId,
  musicBrainzReleaseTrackId,
  musicBrainzReleaseId,
  musicBrainzReleaseGroupId,
  musicBrainzArtistIds,
  musicBrainzAlbumArtistIds,
  replayGainTrackGain,
  replayGainTrackPeak,
  replayGainAlbumGain,
  replayGainAlbumPeak;

  bool get isMultiValue => switch (this) {
    TagField.artists ||
    TagField.albumArtists ||
    TagField.genres ||
    TagField.composers ||
    TagField.musicBrainzArtistIds ||
    TagField.musicBrainzAlbumArtistIds => true,
    _ => false,
  };

  bool get isNumeric => switch (this) {
    TagField.trackNumber || TagField.trackTotal || TagField.discNumber || TagField.discTotal => true,
    _ => false,
  };

  /// Fields that usually differ per track and are not offered in the shared
  /// part of an album batch edit.
  bool get isPerTrack => switch (this) {
    TagField.title ||
    TagField.trackNumber ||
    TagField.lyrics ||
    TagField.musicBrainzRecordingId ||
    TagField.musicBrainzReleaseTrackId ||
    TagField.replayGainTrackGain ||
    TagField.replayGainTrackPeak => true,
    _ => false,
  };

  bool get isMusicBrainz => name.startsWith("musicBrainz");

  bool get isReplayGain => name.startsWith("replayGain");
}

/// ID3/FLAC picture types we care about (the full list has 21 entries).
abstract final class PictureType {
  static const other = 0;
  static const frontCover = 3;
  static const backCover = 4;
}

class TagPicture {
  TagPicture({
    required this.data,
    required this.mimeType,
    this.type = PictureType.frontCover,
    this.description = "",
    this.width = 0,
    this.height = 0,
    this.colorDepth = 0,
    this.indexedColors = 0,
  });

  final Uint8List data;
  final String mimeType;
  final int type;
  final String description;
  final int width;
  final int height;
  final int colorDepth;
  final int indexedColors;

  /// Sniffs the image type from the magic bytes; falls back to JPEG.
  static String sniffMimeType(Uint8List bytes) {
    if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return "image/png";
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45) {
      return "image/webp";
    }
    if (bytes.length >= 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return "image/gif";
    return "image/jpeg";
  }

  @override
  bool operator ==(Object other) =>
      other is TagPicture &&
      other.type == type &&
      other.mimeType == mimeType &&
      other.description == description &&
      const ListEquality<int>().equals(other.data, data);

  @override
  int get hashCode => Object.hash(type, mimeType, description, data.length);
}

/// A format-neutral set of tag values. Absent and empty fields mean "no value".
class AudioTags {
  AudioTags({Map<TagField, List<String>>? values, List<TagPicture>? pictures})
    : _values = {
        for (final e in (values ?? const <TagField, List<String>>{}).entries)
          if (_clean(e.value).isNotEmpty) e.key: _clean(e.value),
      },
      pictures = pictures ?? [];

  final Map<TagField, List<String>> _values;
  List<TagPicture> pictures;

  static List<String> _clean(List<String> values) =>
      values.map((v) => v.trim()).where((v) => v.isNotEmpty).toList(growable: false);

  Map<TagField, List<String>> get values => Map.unmodifiable(_values);

  String? operator [](TagField field) => _values[field]?.firstOrNull;

  List<String> all(TagField field) => _values[field] ?? const [];

  int? number(TagField field) => int.tryParse(this[field] ?? "");

  void set(TagField field, List<String> values) {
    final cleaned = _clean(values);
    if (cleaned.isEmpty) {
      _values.remove(field);
    } else {
      _values[field] = field.isMultiValue ? cleaned : [cleaned.join(" ")];
    }
  }

  void setOne(TagField field, String? value) => set(field, value == null ? const [] : [value]);

  void setNumber(TagField field, int? value) => setOne(field, value == null || value <= 0 ? null : "$value");

  TagPicture? get frontCover =>
      pictures.firstWhereOrNull((p) => p.type == PictureType.frontCover) ?? pictures.firstOrNull;

  AudioTags copy() =>
      AudioTags(values: {for (final e in _values.entries) e.key: List.of(e.value)}, pictures: List.of(pictures));

  bool sameValue(AudioTags other, TagField field) => const ListEquality<String>().equals(all(field), other.all(field));

  @override
  String toString() =>
      "AudioTags(${_values.entries.map((e) => "${e.key.name}=${e.value}").join(", ")}, "
      "${pictures.length} picture(s))";
}

/// Splits "3/12" style values used by ID3 TRCK/TPOS and some Vorbis taggers.
(int?, int?) parseNumberPair(String? raw) {
  if (raw == null) return (null, null);
  final parts = raw.split("/");
  final first = int.tryParse(parts[0].trim());
  final second = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
  return (first, second);
}

/// Thrown for files the codecs refuse to touch (unknown container, encrypted
/// frames we can't preserve safely, fragmented MP4...).
class UnsupportedTagFormatException implements Exception {
  const UnsupportedTagFormatException(this.message);

  final String message;

  @override
  String toString() => "UnsupportedTagFormatException: $message";
}
