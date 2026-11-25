import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/formats/vorbis_comment.dart';
import 'package:diapason/services/tag_editor/tag_file.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fixtures.dart';

AudioTags sampleTags({bool withPicture = true, int pictureSize = 64}) => AudioTags(
  values: {
    TagField.title: ["Été — 夏"],
    TagField.artists: ["Artist A", "Artist B"],
    TagField.albumArtists: ["Various"],
    TagField.album: ["The Album"],
    TagField.trackNumber: ["3"],
    TagField.trackTotal: ["12"],
    TagField.discNumber: ["1"],
    TagField.discTotal: ["2"],
    TagField.date: ["2021-05-04"],
    TagField.genres: ["Jazz", "Funk"],
    TagField.composers: ["Comp"],
    TagField.comment: ["A comment"],
    TagField.lyrics: ["Line one\nLine two"],
    TagField.musicBrainzRecordingId: ["11111111-1111-1111-1111-111111111111"],
    TagField.musicBrainzReleaseTrackId: ["22222222-2222-2222-2222-222222222222"],
    TagField.musicBrainzReleaseId: ["33333333-3333-3333-3333-333333333333"],
    TagField.musicBrainzReleaseGroupId: ["44444444-4444-4444-4444-444444444444"],
    TagField.musicBrainzArtistIds: ["55555555-5555-5555-5555-555555555555", "66666666-6666-6666-6666-666666666666"],
    TagField.musicBrainzAlbumArtistIds: ["77777777-7777-7777-7777-777777777777"],
    TagField.replayGainTrackGain: ["-6.50 dB"],
    TagField.replayGainTrackPeak: ["0.988"],
    TagField.replayGainAlbumGain: ["-7.10 dB"],
    TagField.replayGainAlbumPeak: ["0.999"],
  },
  pictures: [
    if (withPicture)
      TagPicture(
        data: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, ...List.generate(pictureSize, (i) => i & 0xFF)]),
        mimeType: "image/png",
      ),
  ],
);

void expectSameTags(AudioTags actual, AudioTags expected, {Set<TagField> skip = const {}}) {
  for (final field in TagField.values) {
    if (skip.contains(field)) continue;
    expect(actual.all(field), expected.all(field), reason: field.name);
  }
  expect(actual.pictures.length, expected.pictures.length);
  for (var i = 0; i < expected.pictures.length; i++) {
    expect(actual.pictures[i].data, expected.pictures[i].data);
    expect(actual.pictures[i].mimeType, expected.pictures[i].mimeType);
  }
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp("diapason_tags_"));
  tearDown(() async => dir.delete(recursive: true));

  Future<File> fixture(String name, Uint8List bytes) async => File("${dir.path}/$name")..writeAsBytesSync(bytes);

  bool endsWith(Uint8List bytes, Uint8List tail) {
    if (bytes.length < tail.length) return false;
    for (var i = 0; i < tail.length; i++) {
      if (bytes[bytes.length - tail.length + i] != tail[i]) return false;
    }
    return true;
  }

  group("ID3v2", () {
    test("writes a v2.4 tag on an untagged MP3 and reads it back", () async {
      final file = await fixture("a.mp3", buildMp3());
      expect(await TagFile.detect(file), TagContainer.id3v2);
      await TagFile.write(file, sampleTags());
      expectSameTags(await TagFile.read(file), sampleTags());
      final bytes = file.readAsBytesSync();
      expect(bytes[3], 4);
      expect(endsWith(bytes, buildMp3()), isTrue, reason: "audio frames untouched");

      final independent = amr.readMetadata(file);
      expect(independent.title, "Été — 夏");
      expect(independent.album, "The Album");
      expect(independent.trackNumber, 3);
    });

    test("keeps a v2.3 tag in v2.3, preserves unknown frames and reuses padding", () async {
      final original = buildMp3(id3: buildId3v23Tag());
      final file = await fixture("b.mp3", original);
      final tags = await TagFile.read(file);
      expect(tags[TagField.title], "Old title");

      tags.setOne(TagField.title, "New");
      tags.set(TagField.artists, ["Ä", "B"]);
      await TagFile.write(file, tags);
      final bytes = file.readAsBytesSync();
      expect(bytes[3], 3);
      expect(bytes.length, original.length, reason: "fits in the old padding");
      expect(indexOfBytes(bytes, latin1.encode("keep me")), greaterThan(0));
      expect(indexOfBytes(bytes, latin1.encode("PRIV")), greaterThan(0));

      final reread = await TagFile.read(file);
      expect(reread[TagField.title], "New");
      // v2.3 has no multi-value text frames: joined with "/".
      expect(reread.all(TagField.artists), ["Ä/B"]);
    });

    test("grows the tag when it no longer fits", () async {
      final file = await fixture("c.mp3", buildMp3(id3: buildId3v23Tag()));
      await TagFile.write(file, sampleTags(pictureSize: 5000));
      final reread = await TagFile.read(file);
      expect(reread.pictures.single.data.length, 5004);
      expect(reread[TagField.musicBrainzRecordingId], "11111111-1111-1111-1111-111111111111");
      expect(endsWith(file.readAsBytesSync(), buildMp3()), isTrue);
    });

    test("clearing every field leaves only foreign frames", () async {
      final file = await fixture("d.mp3", buildMp3());
      await TagFile.write(file, sampleTags());
      await TagFile.write(file, AudioTags());
      final reread = await TagFile.read(file);
      expect(reread.values, isEmpty);
      expect(reread.pictures, isEmpty);
    });
  });

  group("FLAC", () {
    test("round-trips every field and keeps other blocks and audio", () async {
      final original = buildFlac(
        comment: VorbisComment(vendor: "ref", entries: [const MapEntry("CUSTOM", "x")]),
      );
      final file = await fixture("a.flac", original);
      await TagFile.write(file, sampleTags(pictureSize: 6000));
      expectSameTags(await TagFile.read(file), sampleTags(pictureSize: 6000));
      final bytes = file.readAsBytesSync();
      expect(endsWith(bytes, fakeAudioPayload()), isTrue);
      expect(indexOfBytes(bytes, ascii.encode("CUSTOM=x")), greaterThan(0));
      expect(indexOfBytes(bytes, ascii.encode("TEST")), greaterThan(0), reason: "APPLICATION block kept");

      final independent = amr.readMetadata(file);
      expect(independent.title, "Été — 夏");
      expect(independent.trackNumber, 3);
    });

    test("rewrites in place once padding exists", () async {
      final file = await fixture("b.flac", buildFlac());
      await TagFile.write(file, sampleTags());
      final length = file.lengthSync();
      final smaller = sampleTags(withPicture: false)..setOne(TagField.title, "x");
      await TagFile.write(file, smaller);
      expect(file.lengthSync(), length);
      expectSameTags(await TagFile.read(file), smaller);
    });

    test("reads TRACKNUMBER=3/12 style values", () async {
      final file = await fixture(
        "c.flac",
        buildFlac(
          comment: VorbisComment(entries: [const MapEntry("tracknumber", "3/12"), const MapEntry("Year", "1999")]),
        ),
      );
      final tags = await TagFile.read(file);
      expect(tags[TagField.trackNumber], "3");
      expect(tags[TagField.trackTotal], "12");
      expect(tags[TagField.date], "1999");
    });
  });

  group("Ogg Opus", () {
    test("round-trips and renumbers audio pages when the header grows", () async {
      final original = buildOpus();
      final file = await fixture("a.opus", original);
      final originalPages = parseOggPages(original);

      // A big picture needs several header pages.
      await TagFile.write(file, sampleTags(pictureSize: 70000));
      expectSameTags(await TagFile.read(file), sampleTags(pictureSize: 70000));

      final pages = parseOggPages(file.readAsBytesSync());
      expect(pages.every((p) => p.crcOk), isTrue);
      for (var i = 0; i < pages.length; i++) {
        expect(pages[i].sequence, i, reason: "contiguous sequence numbers");
      }
      final oldAudio = originalPages.where((p) => p.granule > 0).toList();
      final newAudio = pages.where((p) => p.granule > 0).toList();
      expect(newAudio.length, oldAudio.length);
      for (var i = 0; i < oldAudio.length; i++) {
        expect(newAudio[i].body, oldAudio[i].body);
        expect(newAudio[i].granule, oldAudio[i].granule);
      }
      expect(pages.first.flags, 2);
      expect(pages.last.flags & 4, 4);

      // Shrinking back renumbers the other way.
      await TagFile.write(
        file,
        AudioTags(
          values: {
            TagField.title: ["t"],
          },
        ),
      );
      final shrunk = parseOggPages(file.readAsBytesSync());
      expect(shrunk.length, originalPages.length);
      expect(shrunk.every((p) => p.crcOk), isTrue);
      expect((await TagFile.read(file))[TagField.title], "t");
    });

    test("preserves unknown comments", () async {
      final file = await fixture(
        "b.opus",
        buildOpus(
          comment: VorbisComment(vendor: "v", entries: [const MapEntry("R128_TRACK_GAIN", "-512")]),
        ),
      );
      await TagFile.write(file, sampleTags(withPicture: false));
      final bytes = file.readAsBytesSync();
      expect(indexOfBytes(bytes, ascii.encode("R128_TRACK_GAIN=-512")), greaterThan(0));
    });
  });

  group("MP4", () {
    test("adds an ilst and shifts chunk offsets when moov precedes mdat", () async {
      final original = buildMp4();
      final file = await fixture("a.m4a", original);
      final audioAt = readStcoOffset(original);
      expect(original.sublist(audioAt, audioAt + 16), fakeAudioPayload().sublist(0, 16));

      await TagFile.write(file, sampleTags());
      expectSameTags(await TagFile.read(file), sampleTags());
      final bytes = file.readAsBytesSync();
      final newAudioAt = readStcoOffset(bytes);
      expect(newAudioAt, greaterThan(audioAt));
      expect(bytes.sublist(newAudioAt, newAudioAt + 16), fakeAudioPayload().sublist(0, 16));

      final independent = amr.readMetadata(file);
      expect(independent.title, "Été — 夏");
      expect(independent.album, "The Album");
    });

    test("leaves offsets alone when moov is after mdat and keeps unknown atoms", () async {
      final unknown = [
        0,
        0,
        0,
        25,
        ...latin1.encode("tmpo"),
        0,
        0,
        0,
        17,
        ...latin1.encode("data"),
        0,
        0,
        0,
        21,
        0,
        0,
        0,
        0,
        0,
      ];
      final original = buildMp4(moovFirst: false, ilst: unknown);
      final file = await fixture("b.m4a", original);
      final audioAt = readStcoOffset(original);
      await TagFile.write(file, sampleTags(withPicture: false));
      final bytes = file.readAsBytesSync();
      expect(readStcoOffset(bytes), audioAt);
      expect(bytes.sublist(audioAt, audioAt + 16), fakeAudioPayload().sublist(0, 16));
      expect(indexOfBytes(bytes, latin1.encode("tmpo")), greaterThan(0));
      expectSameTags(await TagFile.read(file), sampleTags(withPicture: false));
    });
  });

  group("real encoder output (ffmpeg)", () {
    final hasFfmpeg = () {
      try {
        return Process.runSync("ffmpeg", ["-version"]).exitCode == 0 &&
            Process.runSync("ffprobe", ["-version"]).exitCode == 0;
      } catch (_) {
        return false;
      }
    }();

    for (final (ext, codecArgs) in [
      ("mp3", ["-c:a", "libmp3lame"]),
      ("flac", ["-c:a", "flac"]),
      ("ogg", ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]),
      ("opus", ["-c:a", "libopus"]),
      ("m4a", ["-c:a", "aac", "-movflags", "+faststart"]),
    ]) {
      test(ext, () async {
        final path = "${dir.path}/real.$ext";
        final made = Process.runSync("ffmpeg", [
          "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", //
          ...codecArgs, "-metadata", "title=Before", "-metadata", "encoder_note=keep", path,
        ]);
        if (made.exitCode != 0) {
          markTestSkipped("ffmpeg cannot encode $ext: ${made.stderr}");
          return;
        }
        final file = File(path);
        final before = await TagFile.read(file);
        expect(before[TagField.title], "Before");

        final coverPath = "${dir.path}/cover.png";
        Process.runSync("ffmpeg", [
          "-v",
          "error",
          "-f",
          "lavfi",
          "-i",
          "nullsrc=s=512x512,geq=random(1)*255:128:128",
          "-frames:v",
          "1",
          coverPath,
        ]);
        final tags = sampleTags(withPicture: false)
          ..pictures = [TagPicture(data: File(coverPath).readAsBytesSync(), mimeType: "image/png")];
        expect(tags.pictures.single.data.length, greaterThan(10000));
        await TagFile.write(file, tags);
        expectSameTags(await TagFile.read(file), tags);

        final probe = Process.runSync("ffprobe", [
          "-v", "error", "-select_streams", "a:0", "-show_entries", "format_tags:stream_tags", "-of", "json", path, //
        ]);
        expect(probe.exitCode, 0, reason: "${probe.stderr}");
        final json = jsonDecode(probe.stdout as String) as Map;
        final formatTags = {
          ...?((json["format"] as Map?)?["tags"] as Map?),
          ...?(((json["streams"] as List?)?.firstOrNull as Map?)?["tags"] as Map?),
        };
        final lower = {for (final e in formatTags.entries) e.key.toString().toLowerCase(): e.value.toString()};
        expect(lower["title"], "Été — 夏");
        expect(lower["album"], "The Album");

        final decode = Process.runSync("ffmpeg", ["-v", "error", "-i", path, "-map", "0:a", "-f", "null", "-"]);
        expect(decode.exitCode, 0, reason: "${decode.stderr}");
        expect((decode.stderr as String).trim(), isEmpty, reason: "audio still decodes cleanly");
      }, skip: hasFfmpeg ? false : "ffmpeg/ffprobe not installed");
    }
  });

  test("unknown containers are refused", () async {
    final file = await fixture("x.wav", Uint8List.fromList(ascii.encode("RIFF....WAVEfmt ")));
    expect(() => TagFile.read(file), throwsA(isA<UnsupportedTagFormatException>()));
  });
}
