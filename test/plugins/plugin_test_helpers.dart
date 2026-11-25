import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A zip of [files] (path -> String or bytes).
Uint8List zipOf(Map<String, Object> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = entry.value is String ? utf8.encode(entry.value as String) : entry.value as List<int>;
    archive.add(ArchiveFile.bytes(entry.key, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

/// The zip of an example plugin folder under plugins/examples, without its sources.
Uint8List zipExample(String name) {
  final dir = Directory("plugins/examples/$name");
  final files = <String, Object>{};
  for (final entity in dir.listSync()) {
    if (entity is File && (entity.path.endsWith(".json") || entity.path.endsWith(".wasm"))) {
      files[entity.uri.pathSegments.last] = entity.readAsBytesSync();
    }
  }
  return zipOf(files);
}

Map<String, Object?> manifestJson({
  String id = "org.example.test",
  String runtime = "declarative",
  String entry = "handlers.json",
  List<Object?>? permissions,
  List<Object?>? extensions,
  String minAppVersion = "0.1.0",
}) => {
  "manifestVersion": 1,
  "id": id,
  "name": "Test plugin",
  "version": "1.0.0",
  "author": "Someone",
  "minAppVersion": minAppVersion,
  "runtime": runtime,
  "entry": entry,
  "permissions":
      permissions ??
      [
        {
          "type": "network",
          "hosts": ["api.example.com"],
        },
      ],
  "extensions":
      extensions ??
      [
        {"point": "lyrics"},
      ],
};
