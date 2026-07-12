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

    _progressSubscription = source.downloadProgressStream.listen(
      (progress) {
        prefetch.value = progress >= 1.0 ? null : StreamPrefetch(title: title, fraction: progress);
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

  Future<List<File>> _entries() async => (await _allFiles()).where((f) => !_isSidecar(f)).toList();

  static int _sizeOf(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  Future<int> currentSizeBytes() async {
    var total = 0;
    for (final file in await _allFiles()) {
      total += _sizeOf(file);
    }
    return total;
  }

  bool _isDownloading(File entry) => File("${entry.path}.part").existsSync();

  Future<void> prune({File? keep}) async {
    if (!enabled) return;

    var total = await currentSizeBytes();
    if (total <= maxBytes) return;

    final entries = await _entries();
    entries.sort((a, b) {
      try {
        return a.lastModifiedSync().compareTo(b.lastModifiedSync());
      } catch (_) {
        return 0;
      }
    });

    for (final entry in entries) {
      if (total <= maxBytes) break;
      if (keep != null && p.equals(entry.path, keep.path)) continue;
      if (_isDownloading(entry)) continue;

      total -= _evict(entry);
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
