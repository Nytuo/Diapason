import 'dart:io';

import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;

class LocalUploadSummary {
  const LocalUploadSummary({this.stored = 0, this.duplicates = 0, this.failures = const []});

  final int stored;
  final int duplicates;

  final List<String> failures;

  int get total => stored + duplicates + failures.length;

  String get message {
    final parts = <String>[
      if (stored > 0) "$stored uploaded",
      if (duplicates > 0) "$duplicates already on the server",
      if (failures.isNotEmpty) "${failures.length} failed",
    ];
    return parts.isEmpty ? "Nothing to upload" : parts.join(" · ");
  }
}

class LocalFileUpload {
  static ({String artist, String title}) guessTags(String path) {
    final name = p.basenameWithoutExtension(path).trim();
    final split = name.split(RegExp(r"\s+[-–—]\s+"));
    if (split.length >= 2) {
      return (artist: split.first.trim(), title: split.sublist(1).join(" - ").trim());
    }
    return (artist: "", title: name);
  }

  static Future<LocalUploadSummary?> pickAndUpload({
    void Function(int done, int total, String name)? onProgress,
  }) async {
    final picked = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: UploaderClient.audioExtensions,
    );
    if (picked == null) return null;

    final files = picked.files.where((f) => f.path != null).toList();
    final uploader = GetIt.instance<UploaderClient>();

    var stored = 0, duplicates = 0;
    final failures = <String>[];
    for (var i = 0; i < files.length; i++) {
      final path = files[i].path!;
      onProgress?.call(i, files.length, p.basename(path));
      final tags = guessTags(path);
      final result = await uploader.uploadFile(File(path), artist: tags.artist, title: tags.title);
      if (!result.ok) {
        failures.add("${p.basename(path)}: ${result.message}");

        if (failures.length >= 3 && stored + duplicates == 0) break;
      } else if (result.duplicate) {
        duplicates++;
      } else {
        stored++;
      }
    }
    onProgress?.call(files.length, files.length, "");
    return LocalUploadSummary(stored: stored, duplicates: duplicates, failures: failures);
  }
}
