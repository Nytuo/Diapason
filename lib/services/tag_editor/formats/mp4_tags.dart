import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/formats/file_rewrite.dart';

/// iTunes-style MP4 metadata (`moov/udta/meta/ilst`) for M4A/ALAC/AAC files.
///
/// Only the `moov` box is rebuilt; unknown ilst items are kept. When `moov`
/// sits before the media data and changes size, every `stco`/`co64` chunk
/// offset pointing past it is shifted accordingly.
abstract final class Mp4Tags {
  static const _mean = "com.apple.iTunes";

  static const Map<TagField, String> _textAtoms = {
    TagField.title: "©nam",
    TagField.artists: "©ART",
    TagField.albumArtists: "aART",
    TagField.album: "©alb",
    TagField.date: "©day",
    TagField.genres: "©gen",
    TagField.composers: "©wrt",
    TagField.comment: "©cmt",
    TagField.lyrics: "©lyr",
  };

  /// Freeform `----:com.apple.iTunes:<name>` atoms (Picard naming).
  static const Map<TagField, String> _freeform = {
    TagField.musicBrainzRecordingId: "MusicBrainz Track Id",
    TagField.musicBrainzReleaseTrackId: "MusicBrainz Release Track Id",
    TagField.musicBrainzReleaseId: "MusicBrainz Album Id",
    TagField.musicBrainzReleaseGroupId: "MusicBrainz Release Group Id",
    TagField.musicBrainzArtistIds: "MusicBrainz Artist Id",
    TagField.musicBrainzAlbumArtistIds: "MusicBrainz Album Artist Id",
    TagField.replayGainTrackGain: "replaygain_track_gain",
    TagField.replayGainTrackPeak: "replaygain_track_peak",
    TagField.replayGainAlbumGain: "replaygain_album_gain",
    TagField.replayGainAlbumPeak: "replaygain_album_peak",
  };

  static Future<AudioTags> read(File file) async {
    final layout = await _readLayout(file);
    final ilst = _findPath(layout.moov, const ["udta", "meta", "ilst"]);
    if (ilst == null) return AudioTags();
    return _itemsToTags(_parseBoxes(ilst, 0, ilst.length));
  }

  static Future<void> write(File file, AudioTags tags) async {
    final layout = await _readLayout(file);
    final newMoovPayload = _rebuildMoov(layout.moov, tags);
    final newMoov = _box("moov", newMoovPayload);
    final delta = newMoov.length - layout.moovSize;
    if (delta != 0) {
      if (layout.hasMoof) {
        throw const UnsupportedTagFormatException("Fragmented MP4 files are not supported");
      }
      _shiftChunkOffsets(newMoov, layout.moovStart, delta);
    }
    await rewriteFile(file, [
      SourceRange(0, layout.moovStart),
      BytesSegment(newMoov),
      SourceRange(layout.moovStart + layout.moovSize),
    ]);
  }

  // ---- reading ---------------------------------------------------------

  static AudioTags _itemsToTags(List<_Box> items) {
    final tags = AudioTags();
    for (final MapEntry(key: field, value: atom) in _textAtoms.entries) {
      final item = items.where((b) => b.type == atom).firstOrNull;
      if (item != null) tags.set(field, _dataValues(item.payload).map((d) => d.text).toList());
    }
    for (final (atom, numberField, totalField) in [
      ("trkn", TagField.trackNumber, TagField.trackTotal),
      ("disk", TagField.discNumber, TagField.discTotal),
    ]) {
      final value = items
          .where((b) => b.type == atom)
          .map((b) => _dataValues(b.payload).firstOrNull)
          .nonNulls
          .firstOrNull;
      if (value == null || value.bytes.length < 6) continue;
      final d = ByteData.sublistView(value.bytes);
      tags.setNumber(numberField, d.getUint16(2));
      tags.setNumber(totalField, d.getUint16(4));
    }
    for (final item in items.where((b) => b.type == "----")) {
      final (mean, name, values) = _decodeFreeform(item.payload);
      if (mean != _mean || name == null) continue;
      for (final MapEntry(key: field, value: atomName) in _freeform.entries) {
        if (atomName.toLowerCase() == name.toLowerCase()) tags.set(field, values.map((d) => d.text).toList());
      }
    }
    final covr = items.where((b) => b.type == "covr").firstOrNull;
    if (covr != null) {
      for (final d in _dataValues(covr.payload)) {
        final mime = switch (d.type) {
          14 => "image/png",
          27 => "image/bmp",
          _ => TagPicture.sniffMimeType(d.bytes),
        };
        tags.pictures.add(TagPicture(data: Uint8List.fromList(d.bytes), mimeType: mime));
      }
    }
    return tags;
  }

  static List<_Data> _dataValues(Uint8List itemPayload) => _parseBoxes(itemPayload, 0, itemPayload.length)
      .where((b) => b.type == "data" && b.payload.length >= 8)
      .map((b) => _Data(ByteData.sublistView(b.payload).getUint32(0) & 0xFFFFFF, Uint8List.sublistView(b.payload, 8)))
      .toList();

  static (String?, String?, List<_Data>) _decodeFreeform(Uint8List payload) {
    final children = _parseBoxes(payload, 0, payload.length);
    String? str(String type) {
      final b = children.where((c) => c.type == type).firstOrNull;
      return b == null || b.payload.length < 4 ? null : utf8.decode(b.payload.sublist(4), allowMalformed: true);
    }

    return (str("mean"), str("name"), _dataValues(payload));
  }

  // ---- writing ---------------------------------------------------------

  static Uint8List _rebuildMoov(Uint8List moov, AudioTags tags) {
    final children = _parseBoxes(moov, 0, moov.length);
    final udta = children.where((b) => b.type == "udta").firstOrNull;
    final newUdta = _rebuildUdta(udta?.payload ?? Uint8List(0), tags);
    final out = BytesBuilder(copy: false);
    for (final c in children) {
      out.add(c.type == "udta" ? _box("udta", newUdta) : c.raw);
    }
    if (udta == null) out.add(_box("udta", newUdta));
    return out.toBytes();
  }

  static Uint8List _rebuildUdta(Uint8List udta, AudioTags tags) {
    final children = _parseBoxes(udta, 0, udta.length);
    final meta = children.where((b) => b.type == "meta").firstOrNull;
    final newMeta = _rebuildMeta(meta?.payload, tags);
    final out = BytesBuilder(copy: false);
    for (final c in children) {
      out.add(c.type == "meta" ? _box("meta", newMeta) : c.raw);
    }
    if (meta == null) out.add(_box("meta", newMeta));
    return out.toBytes();
  }

  static Uint8List _rebuildMeta(Uint8List? meta, AudioTags tags) {
    final out = BytesBuilder(copy: false);
    if (meta == null) {
      out.add(const [0, 0, 0, 0]);
      out.add(
        _box("hdlr", Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0, ...latin1.encode("mdirappl"), ...List.filled(9, 0)])),
      );
      out.add(_box("ilst", _buildIlst(const [], tags)));
      return out.toBytes();
    }
    // QuickTime-style `meta` boxes omit the full-box version/flags.
    final isFullBox = !(meta.length >= 8 && latin1.decode(meta.sublist(4, 8)) == "hdlr");
    final start = isFullBox ? 4 : 0;
    if (isFullBox) out.add(meta.sublist(0, 4));
    final children = _parseBoxes(meta, start, meta.length);
    final ilst = children.where((b) => b.type == "ilst").firstOrNull;
    final newIlst = _buildIlst(ilst == null ? const [] : _parseBoxes(ilst.payload, 0, ilst.payload.length), tags);
    for (final c in children) {
      out.add(c.type == "ilst" ? _box("ilst", newIlst) : c.raw);
    }
    if (ilst == null) out.add(_box("ilst", newIlst));
    return out.toBytes();
  }

  static Uint8List _buildIlst(List<_Box> items, AudioTags tags) {
    final managedFreeform = _freeform.values.map((n) => n.toLowerCase()).toSet();
    final kept = items.where((b) {
      if (_textAtoms.values.contains(b.type)) return false;
      if (const {"trkn", "disk", "gnre", "covr"}.contains(b.type)) return false;
      if (b.type == "----") {
        final (mean, name, _) = _decodeFreeform(b.payload);
        return !(mean == _mean && name != null && managedFreeform.contains(name.toLowerCase()));
      }
      return true;
    });

    final out = BytesBuilder(copy: false);
    for (final b in kept) {
      out.add(b.raw);
    }
    for (final MapEntry(key: field, value: atom) in _textAtoms.entries) {
      final values = tags.all(field);
      if (values.isNotEmpty) out.add(_box(atom, _dataBoxes(values.map((v) => (1, utf8.encode(v))))));
    }
    for (final (atom, numberField, totalField, length) in [
      ("trkn", TagField.trackNumber, TagField.trackTotal, 8),
      ("disk", TagField.discNumber, TagField.discTotal, 6),
    ]) {
      final n = tags.number(numberField);
      final total = tags.number(totalField);
      if (n == null && total == null) continue;
      final value = ByteData(length)
        ..setUint16(2, (n ?? 0).clamp(0, 0xFFFF))
        ..setUint16(4, (total ?? 0).clamp(0, 0xFFFF));
      out.add(_box(atom, _dataBoxes([(0, value.buffer.asUint8List())])));
    }
    for (final MapEntry(key: field, value: name) in _freeform.entries) {
      final values = tags.all(field);
      if (values.isEmpty) continue;
      final payload = BytesBuilder(copy: false)
        ..add(_box("mean", Uint8List.fromList([0, 0, 0, 0, ...utf8.encode(_mean)])))
        ..add(_box("name", Uint8List.fromList([0, 0, 0, 0, ...utf8.encode(name)])))
        ..add(_dataBoxes(values.map((v) => (1, utf8.encode(v)))));
      out.add(_box("----", payload.toBytes()));
    }
    if (tags.pictures.isNotEmpty) {
      out.add(
        _box(
          "covr",
          _dataBoxes(
            tags.pictures.map((p) => (p.mimeType == "image/png" ? 14 : (p.mimeType == "image/bmp" ? 27 : 13), p.data)),
          ),
        ),
      );
    }
    return out.toBytes();
  }

  static Uint8List _dataBoxes(Iterable<(int, List<int>)> values) {
    final out = BytesBuilder(copy: false);
    for (final (type, bytes) in values) {
      final payload = Uint8List(8 + bytes.length);
      ByteData.sublistView(payload).setUint32(0, type);
      payload.setAll(8, bytes);
      out.add(_box("data", payload));
    }
    return out.toBytes();
  }

  static void _shiftChunkOffsets(Uint8List moovBox, int moovStart, int delta) {
    void walk(int start, int end) {
      for (final b in _parseBoxes(moovBox, start, end)) {
        switch (b.type) {
          case "trak" || "mdia" || "minf" || "stbl":
            walk(b.payloadStart, b.end);
          case "stco" || "co64":
            final d = ByteData.sublistView(moovBox);
            final count = d.getUint32(b.payloadStart + 4);
            final wide = b.type == "co64";
            for (var i = 0; i < count; i++) {
              final pos = b.payloadStart + 8 + i * (wide ? 8 : 4);
              if (pos + (wide ? 8 : 4) > b.end) break;
              if (wide) {
                final v = d.getUint64(pos);
                if (v > moovStart) d.setUint64(pos, v + delta);
              } else {
                final v = d.getUint32(pos);
                if (v > moovStart) {
                  final shifted = v + delta;
                  if (shifted > 0xFFFFFFFF) {
                    throw const UnsupportedTagFormatException("Chunk offset overflow; file too large for stco");
                  }
                  d.setUint32(pos, shifted);
                }
              }
            }
        }
      }
    }

    walk(8, moovBox.length);
  }

  // ---- box helpers -----------------------------------------------------

  static Uint8List _box(String type, List<int> payload) {
    final out = Uint8List(8 + payload.length);
    ByteData.sublistView(out).setUint32(0, out.length);
    out.setAll(4, latin1.encode(type));
    out.setAll(8, payload);
    return out;
  }

  static List<_Box> _parseBoxes(Uint8List data, int start, int end) {
    final boxes = <_Box>[];
    final d = ByteData.sublistView(data);
    var pos = start;
    while (pos + 8 <= end) {
      var size = d.getUint32(pos);
      var header = 8;
      if (size == 1) {
        if (pos + 16 > end) break;
        size = d.getUint64(pos + 8);
        header = 16;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < header || pos + size > end) break;
      boxes.add(_Box(data, latin1.decode(data.sublist(pos + 4, pos + 8)), pos, pos + header, pos + size));
      pos += size;
    }
    return boxes;
  }

  static Uint8List? _findPath(Uint8List data, List<String> path) {
    var current = data;
    for (final type in path) {
      var start = 0;
      if (type == "ilst") {
        // We're inside `meta`: skip version/flags unless QuickTime-style.
        final isFull = !(current.length >= 8 && latin1.decode(current.sublist(4, 8)) == "hdlr");
        start = isFull ? 4 : 0;
      }
      final box = _parseBoxes(current, start, current.length).where((b) => b.type == type).firstOrNull;
      if (box == null) return null;
      current = box.payload;
    }
    return current;
  }

  static Future<_Layout> _readLayout(File file) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      var pos = 0;
      int? moovStart;
      var moovSize = 0;
      var hasMoof = false;
      var sawFtyp = false;
      while (pos + 8 <= length) {
        final h = await readRange(raf, pos, 16);
        final d = ByteData.sublistView(h);
        var size = d.getUint32(0);
        final type = latin1.decode(h.sublist(4, 8));
        if (pos == 0 && type == "ftyp") sawFtyp = true;
        if (size == 1 && h.length >= 16) {
          size = d.getUint64(8);
        } else if (size == 0) {
          size = length - pos;
        }
        if (size < 8) throw const FormatException("Invalid MP4 box size");
        if (type == "moov") {
          moovStart = pos;
          moovSize = size;
        }
        if (type == "moof") hasMoof = true;
        pos += size;
      }
      if (!sawFtyp) throw const UnsupportedTagFormatException("Not an MP4 file");
      if (moovStart == null) throw const FormatException("MP4 file has no moov box");
      final moovHeader = await readRange(raf, moovStart, 8);
      final headerSize = ByteData.sublistView(moovHeader).getUint32(0) == 1 ? 16 : 8;
      final moov = await readRange(raf, moovStart + headerSize, moovSize - headerSize);
      return _Layout(moovStart, moovSize, moov, hasMoof);
    } finally {
      await raf.close();
    }
  }
}

class _Box {
  _Box(this.source, this.type, this.start, this.payloadStart, this.end);

  final Uint8List source;
  final String type;
  final int start;
  final int payloadStart;
  final int end;

  Uint8List get payload => Uint8List.sublistView(source, payloadStart, end);
  Uint8List get raw => Uint8List.sublistView(source, start, end);
}

class _Data {
  _Data(this.type, this.bytes);

  final int type;
  final Uint8List bytes;

  String get text => utf8.decode(bytes, allowMalformed: true);
}

class _Layout {
  _Layout(this.moovStart, this.moovSize, this.moov, this.hasMoof);

  final int moovStart;
  final int moovSize;
  final Uint8List moov;
  final bool hasMoof;
}
