
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/item_mapper.dart';
import 'package:diapason/services/backends/local_backend.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// Enough of a backend to exercise the registry's routing without a server.
class _FakeBackend implements MediaBackend {
  _FakeBackend(this.config);

  @override
  final MediaSourceConfig config;

  @override
  String get sourceId => config.sourceId;

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

MediaSourceConfig _config(String sourceId, MediaSourceKind kind) =>
    MediaSourceConfig(sourceId: sourceId, kind: kind, name: sourceId);

void main() {
  group("source-scoped ids", () {
    test("round-trip through scoping", () {
      final id = BaseItemId.scoped("sub-1a2b", "tr-991");

      expect(id.raw, "sub-1a2b~tr-991");
      expect(id.sourceId, "sub-1a2b");
      expect(id.nativeId, "tr-991");
      expect(id.isScoped, isTrue);
    });

    test("an unscoped id reports no source and is its own native id", () {
      // Jellyfin ids are still raw GUIDs until its call sites move to the registry.
      const id = BaseItemId("7f3ea1b2c3d4");

      expect(id.isScoped, isFalse);
      expect(id.sourceId, "");
      expect(id.nativeId, "7f3ea1b2c3d4");
    });

    test("a native id containing the separator survives a round trip", () {
      // Local ids are hashes, but a server is free to use anything.
      final id = BaseItemId.scoped("px-1", "a~b~c");

      expect(id.sourceId, "px-1");
      expect(id.nativeId, "a~b~c");
    });

    test("two servers reusing the same native id do not collide", () {
      final a = BaseItemId.scoped("jf-1", "shared");
      final b = BaseItemId.scoped("jf-2", "shared");

      // This is the whole point: these become distinct Isar keys and queue ids.
      expect(a.raw, isNot(b.raw));
    });
  });

  group("BackendRegistry routing", () {
    test("routes a scoped id to its owning source", () {
      final registry = BackendRegistry()
        ..register(_FakeBackend(_config("sub-1", MediaSourceKind.subsonic)))
        ..register(_FakeBackend(_config("px-1", MediaSourceKind.plex)));

      expect(registry.forItemId(BaseItemId.scoped("px-1", "42"))?.sourceId, "px-1");
      expect(registry.forItemId(BaseItemId.scoped("sub-1", "42"))?.sourceId, "sub-1");
    });

    test("an unscoped id goes to Jellyfin, even alongside other sources", () {
      // The reason a Navidrome source can be added without breaking Jellyfin.
      final registry = BackendRegistry()
        ..register(_FakeBackend(_config("jf-1", MediaSourceKind.jellyfin)))
        ..register(_FakeBackend(_config("sub-1", MediaSourceKind.subsonic)))
        ..register(_FakeBackend(_config("loc-1", MediaSourceKind.local)));

      expect(registry.forItemId(const BaseItemId("raw-guid"))?.sourceId, "jf-1");
    });

    test("an unscoped id is refused when two Jellyfin servers could own it", () {
      final registry = BackendRegistry()
        ..register(_FakeBackend(_config("jf-1", MediaSourceKind.jellyfin)))
        ..register(_FakeBackend(_config("jf-2", MediaSourceKind.jellyfin)));

      // Ambiguous: better to fail loudly than to guess and corrupt the download DB.
      expect(registry.forItemId(const BaseItemId("raw-guid")), isNull);
    });

    test("an id whose source was removed routes nowhere", () {
      final registry = BackendRegistry()..register(_FakeBackend(_config("sub-1", MediaSourceKind.subsonic)));

      expect(registry.forItemId(BaseItemId.scoped("sub-gone", "42")), isNull);
    });

    test("YouTube is routable but is not a library", () {
      // YouTube is registered so a track found by search can be routed and
      // played, but it is nobody's library: counting it made the splash screen
      // think a fresh install already had sources, so onboarding never appeared.
      final registry = BackendRegistry()..register(_FakeBackend(_config("yt", MediaSourceKind.youtube)));

      expect(registry.forItemId(BaseItemId.scoped("yt", "abc"))?.sourceId, "yt");
      expect(registry.configured, isEmpty);
      expect(registry.enabled, isEmpty);
      expect(registry.isEmpty, isTrue, reason: "a YouTube-only registry still has no library");
    });

    test("a single library alongside YouTube is still a single source", () {
      // Otherwise every request would take the merge path and lose server-side
      // paging, even for someone with one server.
      final registry = BackendRegistry()
        ..register(_FakeBackend(_config("sub-1", MediaSourceKind.subsonic)))
        ..register(_FakeBackend(_config("yt", MediaSourceKind.youtube)));

      expect(registry.enabled.map((b) => b.sourceId), ["sub-1"]);
    });

    test("enabled excludes switched-off sources", () {
      final off = _config("sub-2", MediaSourceKind.subsonic)..enabled = false;
      final registry = BackendRegistry()
        ..register(_FakeBackend(_config("sub-1", MediaSourceKind.subsonic)))
        ..register(_FakeBackend(off));

      expect(registry.enabled.map((b) => b.sourceId), ["sub-1"]);
      expect(registry.all.length, 2);
    });
  });

  group("ItemMapper", () {
    final mapper = ItemMapper("sub-1");

    test("scopes every id it emits, including parents", () {
      final track = mapper.track(
        nativeId: "t1",
        name: "Song",
        album: "Album",
        albumNativeId: "al1",
        artist: "Artist",
        artistNativeId: "ar1",
        duration: const Duration(minutes: 3),
      );

      expect(track.id.raw, "sub-1~t1");
      expect(track.albumId?.raw, "sub-1~al1");
      expect(track.artistItems?.single.id.raw, "sub-1~ar1");
      expect(track.type, "Audio");
      // Jellyfin ticks are 100ns units.
      expect(track.runTimeTicks, const Duration(minutes: 3).inMicroseconds * 10);
    });

    test("omits artist pairs when the server gave no artist id", () {
      // NameIdPair.id is non-null, so a pair without an id cannot be built.
      final track = mapper.track(nativeId: "t1", name: "Song", artist: "Artist");

      expect(track.artistItems, isNull);
      expect(track.albumArtist, "Artist");
    });

    test("an item only claims artwork when the source said it has some", () {
      expect(mapper.album(nativeId: "a1", name: "A", hasImage: true).imageId, "sub-1~a1");
      expect(mapper.album(nativeId: "a2", name: "B").imageId, isNull);
    });
  });

  group("LocalBackend scanning", () {
    // A real, tagged MP3 on disk (test/fixtures/music/test.mp3).
    late LocalBackend backend;

    setUp(() async {
      backend = LocalBackend(
        MediaSourceConfig(sourceId: "loc-1", kind: MediaSourceKind.local, name: "Local")
          ..localPath = "test/fixtures/music",
      );
      await backend.scan();
    });

    test("reads tags and groups the folder into a library", () async {
      final tracks = await backend.getItems(includeItemTypes: "Audio");
      final albums = await backend.getItems(includeItemTypes: "MusicAlbum");
      final artists = await backend.getItems(includeItemTypes: "MusicArtist");

      expect(tracks.single.name, "Test Song");
      expect(tracks.single.albumArtist, "Test Artist");
      expect(tracks.single.indexNumber, 3);
      expect(albums.single.name, "Test Album");
      expect(artists.single.name, "Test Artist");
    });

    test("scopes its ids, and an album's tracks resolve back to it", () async {
      final album = (await backend.getItems(includeItemTypes: "MusicAlbum")).single;
      final tracks = await backend.getItems(parentItem: album);

      expect(album.id.sourceId, "loc-1");
      expect(tracks.single.albumId, album.id);
    });

    test("resolves a track to the file on disk", () async {
      final track = (await backend.getItems(includeItemTypes: "Audio")).single;
      final source = await backend.resolveStream(track, transcode: false);

      expect(source.isLocalFile, isTrue);
      expect(source.uri.toFilePath(), endsWith("test.mp3"));
      expect(source.headers, isEmpty);
    });

    test("ids are stable across rescans, so downloads survive", () async {
      final before = (await backend.getItems(includeItemTypes: "Audio")).single.id;
      await backend.scan();
      final after = (await backend.getItems(includeItemTypes: "Audio")).single.id;

      expect(after, before);
    });
  });

  group("LRC parsing", () {
    test("reads timings, converting to Jellyfin ticks", () {
      final lyrics = LocalBackend.parseLrc("[00:12.50]First line\n[01:05.00]Second line");

      expect(lyrics!.lyrics, hasLength(2));
      expect(lyrics.lyrics![0].text, "First line");
      // 12.5s, in 100ns ticks.
      expect(lyrics.lyrics![0].start, const Duration(seconds: 12, milliseconds: 500).inMicroseconds * 10);
      expect(lyrics.lyrics![1].start, const Duration(minutes: 1, seconds: 5).inMicroseconds * 10);
    });

    test("treats two fractional digits as centiseconds and three as milliseconds", () {
      final centi = LocalBackend.parseLrc("[00:01.05]x")!.lyrics!.single.start;
      final milli = LocalBackend.parseLrc("[00:01.050]x")!.lyrics!.single.start;

      // .05 centiseconds == .050 milliseconds == 50ms. Getting this wrong would
      // desync every line by up to a second.
      expect(centi, const Duration(seconds: 1, milliseconds: 50).inMicroseconds * 10);
      expect(centi, milli);
    });

    test("skips metadata headers, keeping only the timed lines", () {
      final lyrics = LocalBackend.parseLrc("[ar:Some Artist]\n[ti:Title]\n[00:03.00]Actual line");

      expect(lyrics!.lyrics, hasLength(1));
      expect(lyrics.lyrics!.single.text, "Actual line");
    });

    test("returns null when nothing is timed, so the caller can fall back", () {
      expect(LocalBackend.parseLrc("[ar:Some Artist]\n[ti:Title]"), isNull);
      expect(LocalBackend.parseLrc("just plain text\nno timings here"), isNull);
      expect(LocalBackend.parseLrc(""), isNull);
    });
  });
}
