import 'dart:io';

import 'package:diapason/services/transfer/import_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// An import service rooted in a temp directory, so the copy logic can be
/// exercised without Isar or a registered source.
class _TestImportService extends ImportService {
  _TestImportService(this._dir);

  final Directory _dir;

  @override
  Future<Directory> importDirectory() async => _dir;

  // The real one creates a local source and rescans it; neither is what these
  // tests are about.
  @override
  Future<void> rescan([String? sourceId]) async {}
}

void main() {
  late Directory library;
  late Directory elsewhere;
  late _TestImportService importer;

  setUp(() {
    library = Directory.systemTemp.createTempSync("diapason_library");
    elsewhere = Directory.systemTemp.createTempSync("diapason_source");
    importer = _TestImportService(library);
  });

  tearDown(() {
    library.deleteSync(recursive: true);
    elsewhere.deleteSync(recursive: true);
  });

  File given(String name, [String contents = "audio"]) =>
      File(p.join(elsewhere.path, name))..writeAsStringSync(contents);

  test("copies files in, leaving the originals alone", () async {
    final original = given("song.mp3");

    final imported = await importer.importFiles([original]);

    expect(imported, 1);
    expect(File(p.join(library.path, "song.mp3")).existsSync(), isTrue);
    // The file the user picked is theirs — it may live in Downloads or Drive,
    // and we have no business moving it.
    expect(original.existsSync(), isTrue);
  });

  test("does not overwrite an import of the same name", () async {
    // Two albums can each hold a "01 - Intro.mp3".
    await importer.importFiles([given("01 - Intro.mp3", "first")]);
    await importer.importFiles([given("01 - Intro.mp3", "second")]);

    expect(File(p.join(library.path, "01 - Intro.mp3")).readAsStringSync(), "first");
    expect(File(p.join(library.path, "01 - Intro (2).mp3")).readAsStringSync(), "second");
  });

  test("keeps counting when several collide", () async {
    for (final contents in ["a", "b", "c"]) {
      await importer.importFiles([given("track.mp3", contents)]);
    }

    final names = library.listSync().map((f) => p.basename(f.path)).toSet();
    expect(names, {"track.mp3", "track (2).mp3", "track (3).mp3"});
  });

  test("a missing file is skipped, not fatal", () async {
    final imported = await importer.importFiles([
      given("good.mp3"),
      File(p.join(elsewhere.path, "gone.mp3")),
    ]);

    // Losing one of forty is better than losing all forty.
    expect(imported, 1);
    expect(File(p.join(library.path, "good.mp3")).existsSync(), isTrue);
  });

  test("writes downloaded bytes into the library", () async {
    final written = await importer.writeImported("from-desktop.mp3", [1, 2, 3]);

    expect(written, isNotNull);
    expect(File(p.join(library.path, "from-desktop.mp3")).readAsBytesSync(), [1, 2, 3]);
  });

  test("downloaded files collide-rename too", () async {
    await importer.writeImported("dup.mp3", [1]);
    await importer.writeImported("dup.mp3", [2]);

    expect(File(p.join(library.path, "dup.mp3")).readAsBytesSync(), [1]);
    expect(File(p.join(library.path, "dup (2).mp3")).readAsBytesSync(), [2]);
  });
}
