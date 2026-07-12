import 'dart:io';

import 'package:diapason/services/stream_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A cache rooted in a temp directory, with an injectable budget so the test
/// doesn't have to stand up Hive-backed settings.
class _TestCache extends StreamCacheService {
  _TestCache(this._dir, {required this.budget});

  final Directory _dir;
  final int budget;

  @override
  Future<Directory> get directory async => _dir;

  @override
  bool get enabled => true;

  @override
  int get maxBytes => budget;
}

File _write(Directory dir, String name, int bytes, DateTime modified) {
  final file = File(p.join(dir.path, name))..writeAsBytesSync(List.filled(bytes, 0));
  file.setLastModifiedSync(modified);
  return file;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync("diapason_cache_test"));
  tearDown(() => dir.deleteSync(recursive: true));

  test("reports what it is holding", () async {
    _write(dir, "a.mp3", 100, DateTime(2026));
    _write(dir, "b.mp3", 250, DateTime(2026));

    expect(await _TestCache(dir, budget: 1000).currentSizeBytes(), 350);
  });

  test("leaves the cache alone while it fits", () async {
    _write(dir, "a.mp3", 100, DateTime(2026));
    final cache = _TestCache(dir, budget: 1000);

    await cache.prune();

    expect(dir.listSync(), hasLength(1));
  });

  test("evicts least-recently-played first, until it fits", () async {
    _write(dir, "old.mp3", 400, DateTime(2020));
    _write(dir, "middle.mp3", 400, DateTime(2023));
    _write(dir, "new.mp3", 400, DateTime(2026));

    // 1200 bytes held, 900 allowed: the oldest must go, and only the oldest.
    await _TestCache(dir, budget: 900).prune();

    final left = dir.listSync().map((f) => p.basename(f.path)).toSet();
    expect(left, {"middle.mp3", "new.mp3"});
  });

  test("never evicts the file currently being streamed into", () async {
    // Evicting the file LockCachingAudioSource is writing would corrupt playback.
    final streaming = _write(dir, "streaming.mp3", 400, DateTime(2020));
    _write(dir, "other.mp3", 400, DateTime(2026));

    // Budget forces an eviction, and the oldest file is the one being written.
    await _TestCache(dir, budget: 500).prune(keep: streaming);

    final left = dir.listSync().map((f) => p.basename(f.path)).toSet();
    expect(left, {"streaming.mp3"}, reason: "the spared file stays even though it is the oldest");
  });

  test("never evicts a track that is still downloading", () async {
    // just_audio writes `<file>.part` while the download is in flight. Deleting
    // the track (or its .part) mid-download breaks the download that is writing
    // it — this is what made playback fail with the cache on.
    _write(dir, "downloading.mp3", 400, DateTime(2020));
    _write(dir, "downloading.mp3.part", 100, DateTime(2020));
    _write(dir, "done.mp3", 400, DateTime(2026));

    await _TestCache(dir, budget: 500).prune();

    final left = dir.listSync().map((f) => p.basename(f.path)).toSet();
    expect(left, containsAll({"downloading.mp3", "downloading.mp3.part"}));
  });

  test("evicts a track together with its sidecars, leaving no orphans", () async {
    _write(dir, "old.mp3", 400, DateTime(2020));
    _write(dir, "old.mp3.mime", 20, DateTime(2020));
    _write(dir, "new.mp3", 400, DateTime(2026));

    await _TestCache(dir, budget: 500).prune();

    final left = dir.listSync().map((f) => p.basename(f.path)).toSet();
    expect(left, {"new.mp3"});
  });

  test("sidecars count toward the size, but are not evicted on their own", () async {
    _write(dir, "a.mp3", 100, DateTime(2026));
    _write(dir, "a.mp3.mime", 20, DateTime(2026));

    final cache = _TestCache(dir, budget: 1000);

    expect(await cache.currentSizeBytes(), 120);
    await cache.prune();
    // Under budget, so nothing goes — least of all a lone sidecar.
    expect(dir.listSync(), hasLength(2));
  });

  test("clear empties the cache", () async {
    _write(dir, "a.mp3", 100, DateTime(2026));
    _write(dir, "b.mp3", 100, DateTime(2026));
    final cache = _TestCache(dir, budget: 1000);

    await cache.clear();

    expect(dir.listSync(), isEmpty);
    expect(await cache.currentSizeBytes(), 0);
  });
}
