import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class StreamPrefetch {
  const StreamPrefetch({this.title, required this.fraction});

  final String? title;

  final double fraction;

  bool get isComplete => fraction >= 1.0;
}

class StreamCacheService {
  static final _log = Logger("StreamCacheService");

  Directory? _directory;

  Future<Directory> get directory async {
    final existing = _directory;
    if (existing != null) return existing;

    final support = await getApplicationSupportDirectory();
    final cache = Directory(p.join(support.path, "stream_cache"));
    if (!cache.existsSync()) cache.createSync(recursive: true);
    return _directory = cache;
  }

  bool get enabled => FinampSettingsHelper.finampSettings.cacheStreamedTracks;

  int get maxBytes => FinampSettingsHelper.finampSettings.maxCacheSizeMegabytes * 1024 * 1024;

  Future<File> fileFor(BaseItemDto item) async {
    final extension = item.container?.isNotEmpty == true ? item.container! : "mp3";
    return fileForId(item.id.raw, extension);
  }

  Future<File> fileForId(String id, String container) async {
    final dir = await directory;
    final key = sha1.convert(id.codeUnits).toString();
    return File(p.join(dir.path, "$key.$container"));
  }

  final ValueNotifier<StreamPrefetch?> prefetch = ValueNotifier(null);

  StreamSubscription<double>? _progressSubscription;

  void trackProgressOf(LockCachingAudioSource source, {String? title}) {
    _progressSubscription?.cancel();
    prefetch.value = StreamPrefetch(title: title, fraction: 0);

    var shown = 0.0;
    _progressSubscription = source.downloadProgressStream.listen(
      (progress) {
        if (progress >= 1.0) {
          prefetch.value = null;
          return;
        }
        // Progress arrives for every downloaded chunk; only republish (and rebuild the bar) per visible percent.
        if (progress - shown < 0.01 && prefetch.value != null) return;
        shown = progress;
        prefetch.value = StreamPrefetch(title: title, fraction: progress);
      },
      onError: (_) => prefetch.value = null,
      onDone: () => prefetch.value = null,
      cancelOnError: true,
    );
  }

  void stopTracking() {
    _progressSubscription?.cancel();
    _progressSubscription = null;
    prefetch.value = null;
  }

  Future<void> _delete(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  static const _sidecarExtensions = {".part", ".mime"};

  static bool _isSidecar(File file) => _sidecarExtensions.contains(p.extension(file.path).toLowerCase());

  Future<List<File>> _allFiles() async {
    final dir = await directory;
    if (!dir.existsSync()) return const [];
    return dir.listSync().whereType<File>().toList();
  }


  static int _sizeOf(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// Every file in the cache with its stat, read asynchronously in one pass so pruning (run on every track change)
  /// doesn't block the UI thread with thousands of synchronous file-system calls.
  Future<Map<String, FileStat>> _statAll() async {
    final dir = await directory;
    final stats = <String, FileStat>{};
    if (!await dir.exists()) return stats;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        stats[entity.path] = await entity.stat();
      } catch (_) {}
    }
    return stats;
  }

  Future<int> currentSizeBytes() async {
    var total = 0;
    for (final stat in (await _statAll()).values) {
      total += stat.size;
    }
    return total;
  }

  bool _pruning = false;

  Future<void> prune({File? keep}) async {
    if (!enabled || _pruning) return;
    _pruning = true;
    try {
      final stats = await _statAll();
      var total = stats.values.fold<int>(0, (sum, stat) => sum + stat.size);
      if (total <= maxBytes) return;

      final entries = stats.entries.where((e) => !_isSidecar(File(e.key))).toList()
        ..sort((a, b) => a.value.modified.compareTo(b.value.modified));

      for (final entry in entries) {
        if (total <= maxBytes) break;
        if (keep != null && p.equals(entry.key, keep.path)) continue;
        if (stats.containsKey("${entry.key}.part")) continue; // still downloading

        total -= _evict(File(entry.key));
      }
    } finally {
      _pruning = false;
    }
  }

  int _evict(File entry) {
    var freed = 0;
    for (final path in [entry.path, "${entry.path}.part", "${entry.path}.mime"]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        freed += _sizeOf(file);
        file.deleteSync();
      } catch (e) {
        _log.fine("Could not evict $path: $e");
      }
    }
    _log.fine("Evicted ${p.basename(entry.path)} from the stream cache");
    return freed;
  }

  Future<void> clear() async {
    for (final file in await _allFiles()) {
      try {
        file.deleteSync();
      } catch (e) {
        _log.fine("Could not delete ${file.path}: $e");
      }
    }
    _log.info("Cleared the stream cache");
  }
}
