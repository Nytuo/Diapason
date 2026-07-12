import 'dart:io';

import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/local_backend.dart';
import 'package:diapason/services/backends/media_source_service.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ImportService {
  ImportService();

  static final _log = Logger("ImportService");
  static const _sourceName = "Imported";

  Future<Directory> importDirectory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, "imported_music"));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<MediaSourceConfig> ensureImportSource() async {
    final dir = await importDirectory();
    final sources = GetIt.instance<MediaSourceService>();

    final existing = sources.sources.where((s) => s.kind == MediaSourceKind.local && s.localPath == dir.path);
    if (existing.isNotEmpty) return existing.first;

    final config = MediaSourceConfig(
      sourceId: sources.newSourceId(MediaSourceKind.local),
      kind: MediaSourceKind.local,
      name: _sourceName,
      localPath: dir.path,
    );
    await sources.addSource(config);
    _log.info("Created the '$_sourceName' local source at ${dir.path}");
    return config;
  }

  Future<int> importFiles(Iterable<File> files) async {
    final dir = await importDirectory();

    var imported = 0;
    for (final file in files) {
      try {
        if (!file.existsSync()) continue;
        final destination = _uniquePath(dir, p.basename(file.path));
        await file.copy(destination);
        imported++;
      } catch (e) {
        _log.warning("Could not import ${file.path}: $e");
      }
    }

    if (imported > 0) await rescan();
    _log.info("Imported $imported file(s)");
    return imported;
  }

  Future<File?> writeImported(String name, List<int> bytes) async {
    try {
      final dir = await importDirectory();
      final file = File(_uniquePath(dir, name));
      await file.writeAsBytes(bytes);
      return file;
    } catch (e) {
      _log.warning("Could not write '$name': $e");
      return null;
    }
  }

  static String _uniquePath(Directory dir, String name) {
    var candidate = p.join(dir.path, name);
    if (!File(candidate).existsSync()) return candidate;

    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var counter = 2;
    while (File(candidate).existsSync()) {
      candidate = p.join(dir.path, "$stem ($counter)$extension");
      counter++;
    }
    return candidate;
  }

  Future<void> rescan([String? sourceId]) async {
    final id = sourceId ?? (await ensureImportSource()).sourceId;
    final backend = GetIt.instance<BackendRegistry>().bySourceId(id);
    if (backend is LocalBackend) {
      await backend.scan();
    }
  }
}
