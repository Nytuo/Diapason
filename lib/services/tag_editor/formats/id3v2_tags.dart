import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/formats/file_rewrite.dart';

/// ID3v2.3 / ID3v2.4 tags (MP3).
///
/// Frames Diapason doesn't edit are kept as-is (same version, same flags).
/// An existing v2.3 tag stays v2.3 (UTF-16 text), anything else becomes v2.4
/// (UTF-8). The ID3v1 trailer, if any, is left untouched.
abstract final class Id3v2Tags {
  static const _padding = 2048;
  static const _mbOwner = "http://musicbrainz.org";

  static const Map<TagField, String> _textFrames = {
    TagField.title: "TIT2",
    TagField.artists: "TPE1",
    TagField.albumArtists: "TPE2",
    TagField.album: "TALB",
    TagField.genres: "TCON",
    TagField.composers: "TCOM",
  };

  /// TXXX descriptions (Picard naming).
  static const Map<TagField, String> _userTextFrames = {
    TagField.musicBrainzReleaseTrackId: "MusicBrainz Release Track Id",
    TagField.musicBrainzReleaseId: "MusicBrainz Album Id",
    TagField.musicBrainzReleaseGroupId: "MusicBrainz Release Group Id",
    TagField.musicBrainzArtistIds: "MusicBrainz Artist Id",
    TagField.musicBrainzAlbumArtistIds: "MusicBrainz Album Artist Id",
    TagField.replayGainTrackGain: "REPLAYGAIN_TRACK_GAIN",
    TagField.replayGainTrackPeak: "REPLAYGAIN_TRACK_PEAK",
    TagField.replayGainAlbumGain: "REPLAYGAIN_ALBUM_GAIN",
    TagField.replayGainAlbumPeak: "REPLAYGAIN_ALBUM_PEAK",
  };

  static Future<AudioTags> read(File file) async {
    final tag = await _readTag(file);
    return tag == null ? AudioTags() : tag.toTags();
  }

  static Future<void> write(File file, AudioTags tags) async {
    final existing = await _readTag(file);
    final version = existing?.version == 3 ? 3 : 4;
    final frames = existing?.frames ?? <Id3Frame>[];
    final updated = applyTags(frames, tags, version);

    final body = BytesBuilder(copy: false);
    for (final f in updated) {
      body.add(f.encode(version));
    }
    final framesBytes = body.toBytes();
    final oldTotal = existing?.totalSize ?? 0;
    final fitsInPlace = existing != null && framesBytes.length + 10 <= oldTotal && !existing.hadFooter;
    final tagSize = fitsInPlace ? oldTotal - 10 : framesBytes.length + _padding;

    final head = Uint8List(10 + tagSize)
      ..setAll(0, [0x49, 0x44, 0x33, version, 0, 0])
      ..setAll(6, syncsafeEncode(tagSize))
      ..setAll(10, framesBytes);

    if (fitsInPlace) {
      await overwriteHead(file, head);
    } else {
      await rewriteFile(file, [BytesSegment(head), SourceRange(oldTotal)]);
    }
  }

  /// Returns [frames] with every frame Diapason manages replaced by [tags].
  static List<Id3Frame> applyTags(List<Id3Frame> frames, AudioTags tags, int version) {
    final result = List.of(frames);
    String? descriptionOf(Id3Frame f) => f.decodeUserText()?.$1.toLowerCase();

    result.removeWhere((f) {
      if (_textFrames.values.contains(f.id)) return true;
      if (const {"TRCK", "TPOS", "TDRC", "TYER", "TDAT", "TIME", "TRDA", "USLT"}.contains(f.id)) return true;
      if (f.id == "COMM") {
        final desc = f.decodeLangText()?.$1 ?? "";
        return desc.isEmpty;
      }
      if (f.id == "UFID") return f.decodeUfidOwner() == _mbOwner;
      if (f.id == "TXXX") {
        final desc = descriptionOf(f);
        return _userTextFrames.values.any((d) => d.toLowerCase() == desc);
      }
      return false;
    });

    void text(String id, List<String> values) {
      if (values.isEmpty) return;
      result.add(Id3Frame.text(id, values, version));
    }

    for (final MapEntry(key: field, value: id) in _textFrames.entries) {
      text(id, tags.all(field));
    }
    String? pair(TagField n, TagField total) {
      final number = tags[n];
      if (number == null) return null;
      final t = tags[total];
      return t == null ? number : "$number/$t";
    }

    final trck = pair(TagField.trackNumber, TagField.trackTotal);
    if (trck != null) text("TRCK", [trck]);
    final tpos = pair(TagField.discNumber, TagField.discTotal);
    if (tpos != null) text("TPOS", [tpos]);
    final date = tags[TagField.date];
    if (date != null) {
      if (version == 4) {
        text("TDRC", [date]);
      } else {
        text("TYER", [date.length >= 4 ? date.substring(0, 4) : date]);
      }
    }
    final comment = tags[TagField.comment];
    if (comment != null) result.add(Id3Frame.langText("COMM", comment, version));
    final lyrics = tags[TagField.lyrics];
    if (lyrics != null) result.add(Id3Frame.langText("USLT", lyrics, version));
    final recording = tags[TagField.musicBrainzRecordingId];
    if (recording != null) {
      result.add(Id3Frame("UFID", Uint8List.fromList([...latin1.encode(_mbOwner), 0, ...ascii.encode(recording)])));
    }
    for (final MapEntry(key: field, value: desc) in _userTextFrames.entries) {
      final values = tags.all(field);
      if (values.isNotEmpty) result.add(Id3Frame.userText(desc, values, version));
    }

    result.removeWhere((f) => f.id == "APIC");
    for (final p in tags.pictures) {
      result.add(Id3Frame.picture(p, version));
    }
    return result;
  }

  static Future<_Tag?> _readTag(File file) async {
    final raf = await file.open();
    try {
      final header = await readRange(raf, 0, 10);
      if (header.length < 10 || header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) return null;
      final version = header[3];
      final flags = header[5];
      final size = syncsafeDecode(header, 6);
      final hasFooter = version == 4 && (flags & 0x10) != 0;
      final total = 10 + size + (hasFooter ? 10 : 0);
      if (version != 3 && version != 4) {
        throw UnsupportedTagFormatException("ID3v2.$version tags are not supported");
      }
      var body = await readRange(raf, 10, size);
      if (body.length < size) throw const FormatException("Truncated ID3v2 tag");
      // v2.3 applies unsynchronisation to the whole tag; v2.4 marks it per frame.
      if (version == 3 && (flags & 0x80) != 0) body = _deunsync(body);
      var pos = 0;
      if ((flags & 0x40) != 0) {
        pos = version == 3 ? 4 + ByteData.sublistView(body).getUint32(0) : syncsafeDecode(body, 0);
      }
      final frames = <Id3Frame>[];
      while (pos + 10 <= body.length) {
        if (body[pos] == 0) break;
        final id = latin1.decode(body.sublist(pos, pos + 4));
        if (!RegExp(r"^[A-Z0-9]{4}$").hasMatch(id)) break;
        final frameSize = version == 4 ? syncsafeDecode(body, pos + 4) : ByteData.sublistView(body).getUint32(pos + 4);
        final frameFlags = (body[pos + 8] << 8) | body[pos + 9];
        pos += 10;
        if (pos + frameSize > body.length) break;
        var data = Uint8List.fromList(body.sublist(pos, pos + frameSize));
        var outFlags = frameFlags;
        if (version == 4 && ((frameFlags & 0x02) != 0 || (flags & 0x80) != 0)) {
          data = _deunsync(data);
          outFlags &= ~0x02;
        }
        frames.add(Id3Frame(id, data, flags: outFlags, version: version));
        pos += frameSize;
      }
      return _Tag(version, frames, total, hasFooter);
    } finally {
      await raf.close();
    }
  }

  static Uint8List _deunsync(Uint8List data) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < data.length; i++) {
      out.addByte(data[i]);
      if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) i++;
    }
    return out.toBytes();
  }
}

class _Tag {
  _Tag(this.version, this.frames, this.totalSize, this.hadFooter);

  final int version;
  final List<Id3Frame> frames;
  final int totalSize;
  final bool hadFooter;

  AudioTags toTags() {
    final tags = AudioTags();
    Id3Frame? first(String id) => frames.where((f) => f.id == id).firstOrNull;

    for (final MapEntry(key: field, value: id) in Id3v2Tags._textFrames.entries) {
      final values = first(id)?.decodeText();
      if (values != null) tags.set(field, values);
    }
    final (track, trackTotal) = parseNumberPair(first("TRCK")?.decodeText()?.firstOrNull);
    tags.setNumber(TagField.trackNumber, track);
    tags.setNumber(TagField.trackTotal, trackTotal);
    final (disc, discTotal) = parseNumberPair(first("TPOS")?.decodeText()?.firstOrNull);
    tags.setNumber(TagField.discNumber, disc);
    tags.setNumber(TagField.discTotal, discTotal);
    tags.setOne(
      TagField.date,
      first("TDRC")?.decodeText()?.firstOrNull ??
          first("TYER")?.decodeText()?.firstOrNull ??
          first("TDOR")?.decodeText()?.firstOrNull,
    );

    final comments = frames.where((f) => f.id == "COMM").map((f) => f.decodeLangText()).nonNulls.toList();
    tags.setOne(TagField.comment, (comments.where((c) => c.$1.isEmpty).firstOrNull ?? comments.firstOrNull)?.$2);
    tags.setOne(TagField.lyrics, first("USLT")?.decodeLangText()?.$2);

    for (final f in frames.where((f) => f.id == "UFID")) {
      if (f.decodeUfidOwner() == Id3v2Tags._mbOwner) {
        tags.setOne(TagField.musicBrainzRecordingId, f.decodeUfidIdentifier());
      }
    }
    final userTexts = frames.where((f) => f.id == "TXXX").map((f) => f.decodeUserText()).nonNulls.toList();
    for (final MapEntry(key: field, value: desc) in Id3v2Tags._userTextFrames.entries) {
      final match = userTexts.where((u) => u.$1.toLowerCase() == desc.toLowerCase()).firstOrNull;
      if (match == null) continue;
      // v2.3 taggers (Picard) join multiple ids with "/".
      tags.set(field, field.isMultiValue ? match.$2.expand((v) => v.split("/")).toList() : match.$2);
    }

    for (final f in frames.where((f) => f.id == "APIC")) {
      final p = f.decodePicture();
      if (p != null) tags.pictures.add(p);
    }
    return tags;
  }
}

/// A raw ID3v2 frame. [data] is the frame payload (already de-unsynchronised).
class Id3Frame {
  Id3Frame(this.id, this.data, {this.flags = 0, this.version = 4});

  final String id;
  final Uint8List data;
  final int flags;

  /// Version of the tag the frame came from: flag bits differ between 2.3 and 2.4.
  final int version;

  static bool _isLatin1(String s) => s.codeUnits.every((c) => c < 0x100);

  /// Picks the text encoding for [version]: UTF-8 in 2.4; Latin-1 or UTF-16
  /// with BOM in 2.3.
  static int _encodingFor(Iterable<String> values, int version) => version == 4 ? 3 : (values.every(_isLatin1) ? 0 : 1);

  static List<int> _encode(String s, int encoding) => switch (encoding) {
    0 => latin1.encode(s),
    3 => utf8.encode(s),
    _ => [
      0xFF,
      0xFE,
      for (final c in s.codeUnits) ...[c & 0xFF, c >> 8],
    ],
  };

  static List<int> _terminator(int encoding) => encoding == 1 || encoding == 2 ? const [0, 0] : const [0];

  factory Id3Frame.text(String id, List<String> values, int version) {
    final enc = _encodingFor(values, version);
    final joined = version == 4 ? values : [values.join("/")];
    final out = <int>[enc];
    for (var i = 0; i < joined.length; i++) {
      if (i > 0) out.addAll(_terminator(enc));
      out.addAll(_encode(joined[i], enc));
    }
    return Id3Frame(id, Uint8List.fromList(out), version: version);
  }

  factory Id3Frame.userText(String description, List<String> values, int version) {
    final enc = _encodingFor([description, ...values], version);
    final joined = version == 4 ? values : [values.join("/")];
    final out = <int>[enc, ..._encode(description, enc), ..._terminator(enc)];
    for (var i = 0; i < joined.length; i++) {
      if (i > 0) out.addAll(_terminator(enc));
      out.addAll(_encode(joined[i], enc));
    }
    return Id3Frame("TXXX", Uint8List.fromList(out), version: version);
  }

  /// COMM / USLT with language "eng" and an empty description.
  factory Id3Frame.langText(String id, String text, int version) {
    final enc = _encodingFor([text], version);
    return Id3Frame(
      id,
      Uint8List.fromList([enc, 0x65, 0x6E, 0x67, ..._encode("", enc), ..._terminator(enc), ..._encode(text, enc)]),
      version: version,
    );
  }

  factory Id3Frame.picture(TagPicture p, int version) {
    final enc = _encodingFor([p.description], version);
    return Id3Frame(
      "APIC",
      Uint8List.fromList([
        enc,
        ...latin1.encode(p.mimeType),
        0,
        p.type,
        ..._encode(p.description, enc),
        ..._terminator(enc),
        ...p.data,
      ]),
      version: version,
    );
  }

  Uint8List encode(int targetVersion) {
    final out = Uint8List(10 + data.length);
    out.setAll(0, latin1.encode(id));
    if (targetVersion == 4) {
      out.setAll(4, syncsafeEncode(data.length));
    } else {
      ByteData.sublistView(out).setUint32(4, data.length);
    }
    out[8] = (flags >> 8) & 0xFF;
    out[9] = flags & 0xFF;
    out.setAll(10, data);
    return out;
  }

  /// Payload after grouping/data-length prefixes, or null for compressed or
  /// encrypted frames (kept opaque).
  Uint8List? get _payload {
    var offset = 0;
    if (version == 4) {
      if ((flags & 0x0C) != 0) return null;
      if ((flags & 0x40) != 0) offset += 1;
      if ((flags & 0x01) != 0) offset += 4;
    } else {
      if ((flags & 0xC0) != 0) return null;
      if ((flags & 0x20) != 0) offset += 1;
    }
    return offset > data.length ? null : Uint8List.sublistView(data, offset);
  }

  static (String, int) _decodeString(Uint8List b, int start, int encoding, {bool terminated = true}) {
    final wide = encoding == 1 || encoding == 2;
    var end = b.length;
    var next = b.length;
    if (terminated) {
      if (wide) {
        for (var i = start; i + 1 < b.length; i += 2) {
          if (b[i] == 0 && b[i + 1] == 0) {
            end = i;
            next = i + 2;
            break;
          }
        }
      } else {
        final i = b.indexOf(0, start);
        if (i >= 0) {
          end = i;
          next = i + 1;
        }
      }
    }
    final bytes = b.sublist(start, end);
    final text = switch (encoding) {
      0 => latin1.decode(bytes),
      3 => utf8.decode(bytes, allowMalformed: true),
      _ => _decodeUtf16(bytes, bigEndianDefault: encoding == 2),
    };
    return (text, next);
  }

  static String _decodeUtf16(List<int> bytes, {required bool bigEndianDefault}) {
    var bigEndian = bigEndianDefault;
    var start = 0;
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        bigEndian = false;
        start = 2;
      } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        bigEndian = true;
        start = 2;
      }
    }
    final units = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      units.add(bigEndian ? (bytes[i] << 8) | bytes[i + 1] : bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  List<String> _splitValues(Uint8List b, int start, int encoding) {
    final values = <String>[];
    var pos = start;
    while (pos < b.length) {
      final (text, next) = _decodeString(b, pos, encoding);
      values.add(text);
      if (next >= b.length || next == pos) break;
      pos = next;
    }
    return values.where((v) => v.isNotEmpty).toList();
  }

  List<String>? decodeText() {
    final b = _payload;
    if (b == null || b.isEmpty) return null;
    return _splitValues(b, 1, b[0]);
  }

  (String, List<String>)? decodeUserText() {
    final b = _payload;
    if (b == null || b.isEmpty) return null;
    final (desc, next) = _decodeString(b, 1, b[0]);
    return (desc, _splitValues(b, next, b[0]));
  }

  (String, String)? decodeLangText() {
    final b = _payload;
    if (b == null || b.length < 4) return null;
    final (desc, next) = _decodeString(b, 4, b[0]);
    final (text, _) = _decodeString(b, next, b[0], terminated: false);
    return (desc, text.replaceAll("\u0000", ""));
  }

  String? decodeUfidOwner() {
    final b = _payload;
    if (b == null) return null;
    return _decodeString(b, 0, 0).$1;
  }

  String? decodeUfidIdentifier() {
    final b = _payload;
    if (b == null) return null;
    final (_, next) = _decodeString(b, 0, 0);
    return next >= b.length ? null : latin1.decode(b.sublist(next));
  }

  TagPicture? decodePicture() {
    final b = _payload;
    if (b == null || b.length < 4) return null;
    final enc = b[0];
    final (mime, afterMime) = _decodeString(b, 1, 0);
    if (afterMime >= b.length) return null;
    final type = b[afterMime];
    final (desc, afterDesc) = _decodeString(b, afterMime + 1, enc);
    if (afterDesc > b.length) return null;
    final image = Uint8List.fromList(b.sublist(afterDesc));
    return TagPicture(
      data: image,
      mimeType: mime.isEmpty || !mime.contains("/") ? TagPicture.sniffMimeType(image) : mime,
      type: type,
      description: desc,
    );
  }
}
