import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/match/musicbrainz.dart';
import 'package:diapason/services/tag_editor/server_tag_mapping.dart';
import 'package:diapason/services/tag_editor/tag_edit_session.dart';
import 'package:diapason/services/tag_editor/tag_edit_target.dart';
import 'package:diapason/services/tag_editor/tag_file.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fixtures.dart';

BaseItemDto track(String id, {String? name}) => BaseItemDto(id: BaseItemId(id), name: name, type: "Audio");

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp("diapason_session_"));
  tearDown(() async => dir.delete(recursive: true));

  Future<LocalFileTarget> localTrack(String name, Uint8List bytes, AudioTags tags) async {
    final file = File("${dir.path}/$name")..writeAsBytesSync(bytes);
    await TagFile.write(file, tags);
    return LocalFileTarget(track(name, name: name), file);
  }

  group("album batch on local files", () {
    late TagEditSession session;

    setUp(() async {
      session = TagEditSession(
        item: BaseItemDto(id: const BaseItemId("album"), name: "Old", type: "MusicAlbum"),
        tracks: [
          await localTrack(
            "1.mp3",
            buildMp3(),
            AudioTags(
              values: {
                TagField.title: ["One More Time"],
                TagField.album: ["Old"],
                TagField.trackNumber: ["1"],
                TagField.comment: ["first"],
              },
            ),
          ),
          await localTrack(
            "2.flac",
            buildFlac(),
            AudioTags(
              values: {
                TagField.title: ["digital love"],
                TagField.album: ["Old"],
                TagField.comment: ["second"],
              },
            ),
          ),
        ],
      );
      await session.load();
    });

    test("shared values, mixed values and per-track edits", () async {
      expect(session.shared(TagField.album), ["Old"]);
      expect(session.shared(TagField.comment), isNull, reason: "differs per track");
      expect(session.hasChanges, isFalse);

      session.setShared(TagField.album, ["New Album"]);
      session.setTrack(1, TagField.trackNumber, ["3"]);
      session.setCover(CoverReplaced(Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3])));
      expect(session.changedFields(0), {TagField.album});
      expect(session.changedFields(1), {TagField.album, TagField.trackNumber});

      expect(await session.save(), isEmpty);
      final one = await TagFile.read(session.tracks[0].localFile!);
      final two = await TagFile.read(session.tracks[1].localFile!);
      expect(one[TagField.album], "New Album");
      expect(two[TagField.album], "New Album");
      expect(one[TagField.comment], "first", reason: "untouched per-track values survive");
      expect(two[TagField.comment], "second");
      expect(two[TagField.trackNumber], "3");
      expect(one.frontCover?.mimeType, "image/jpeg");
      expect(two.frontCover?.data, [0xFF, 0xD8, 0xFF, 1, 2, 3]);
      expect(session.hasChanges, isFalse);
    });

    test("applying a MusicBrainz release pairs tracks by number and title", () async {
      final release = MbRelease.parse(
        jsonDecode(File("test/tag_editor/fixtures/mb_release_lookup.json").readAsStringSync()) as Map<String, dynamic>,
      );
      expect(session.applyRelease(release), 2);
      expect(session.edited[0][TagField.title], "One More Time");
      expect(session.edited[1][TagField.title], "Digital Love");
      expect(session.edited[1][TagField.trackNumber], "3");
      expect(session.shared(TagField.album), ["Discovery"]);
      expect(session.shared(TagField.musicBrainzReleaseId), [release.id]);
      expect(session.edited[0][TagField.comment], "first");
    });

    test("removing the cover", () async {
      session.setCover(CoverReplaced(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])));
      await session.save();
      expect(session.embeddedCover?.mimeType, "image/png");
      session.setCover(const CoverRemoved());
      await session.save();
      expect((await TagFile.read(session.tracks[1].localFile!)).pictures, isEmpty);
    });
  });

  test("read-only targets block edits", () async {
    final session = TagEditSession(
      item: track("x"),
      tracks: [ReadOnlyTarget(track("x", name: "Song"), TagReadOnlyReason.subsonic)],
    );
    await session.load();
    expect(session.edited.single[TagField.title], "Song");
    expect(session.canEditAnything, isFalse);
    expect(session.readOnlyReason, TagReadOnlyReason.subsonic);
    session.setShared(TagField.title, ["Other"]);
    expect(session.edited.single[TagField.title], "Song");
  });

  group("Jellyfin mapping", () {
    final item = {
      "Name": "Digital Love",
      "Id": "abc",
      "Album": "Discovery",
      "Artists": ["Daft Punk"],
      "ArtistItems": [
        {"Name": "Daft Punk", "Id": "1"},
      ],
      "AlbumArtists": [
        {"Name": "Daft Punk", "Id": "1"},
      ],
      "IndexNumber": 3,
      "ParentIndexNumber": 1,
      "ProductionYear": 2001,
      "PremiereDate": "2001-03-12T00:00:00.0000000Z",
      "Genres": ["House"],
      "People": [
        {"Name": "Thomas Bangalter", "Type": "Composer"},
        {"Name": "Someone", "Type": "Producer"},
      ],
      "ProviderIds": {"MusicBrainzAlbum": "rel", "MusicBrainzArtist": "a1"},
      "Tags": ["keep"],
      "LockedFields": <String>[],
    };

    test("reads item JSON", () {
      final tags = JellyfinTagMapping.toTags(item);
      expect(tags[TagField.title], "Digital Love");
      expect(tags[TagField.trackNumber], "3");
      expect(tags[TagField.date], "2001-03-12");
      expect(tags.all(TagField.composers), ["Thomas Bangalter"]);
      expect(tags[TagField.musicBrainzReleaseId], "rel");
    });

    test("writes only the edited fields and keeps the rest", () {
      final tags = JellyfinTagMapping.toTags(item)
        ..setOne(TagField.title, "New")
        ..set(TagField.composers, ["A", "B"])
        ..setOne(TagField.date, "1999")
        ..setOne(TagField.musicBrainzRecordingId, "rec")
        ..setOne(TagField.genres, "Should not be sent");
      final out = JellyfinTagMapping.apply(item, tags, {
        TagField.title,
        TagField.composers,
        TagField.date,
        TagField.musicBrainzRecordingId,
      });
      expect(out["Name"], "New");
      expect(out["Genres"], ["House"]);
      expect(out["Tags"], ["keep"]);
      expect(out["ProductionYear"], 1999);
      expect(out["PremiereDate"], startsWith("1999-01-01"));
      expect((out["People"] as List).map((p) => (p as Map)["Name"]), ["Someone", "A", "B"]);
      expect(out["ProviderIds"], {"MusicBrainzAlbum": "rel", "MusicBrainzArtist": "a1", "MusicBrainzRecording": "rec"});
      expect(item["Name"], "Digital Love", reason: "input not mutated");
    });
  });

  group("Plex mapping", () {
    test("track edit params lock the fields", () {
      final tags = AudioTags(
        values: {
          TagField.title: ["T"],
          TagField.trackNumber: ["4"],
        },
      );
      final params = PlexTagMapping.editParams("42", tags, {TagField.title, TagField.trackNumber}, isAlbum: false);
      expect(params, {
        "type": "10",
        "id": "42",
        "title.value": "T",
        "title.locked": "1",
        "index.value": "4",
        "index.locked": "1",
      });
    });

    test("album genres add new ones and remove dropped ones", () {
      final tags = AudioTags(
        values: {
          TagField.genres: ["House", "Disco"],
          TagField.date: ["2001-03-12"],
        },
      );
      final params = PlexTagMapping.editParams(
        "7",
        tags,
        {TagField.genres, TagField.date},
        isAlbum: true,
        previousGenres: ["House", "Electronic"],
      );
      expect(params["type"], "9");
      expect(params["genre[0].tag.tag"], "House");
      expect(params["genre[1].tag.tag"], "Disco");
      expect(params["genre[].tag.tag-"], "Electronic");
      expect(params["originallyAvailableAt.value"], "2001-03-12");
      expect(params["year.value"], "2001");
    });
  });
}
