import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/uploader/youtube_library_import.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class YouTubeUploadButton extends StatelessWidget {
  const YouTubeUploadButton({super.key, required this.track});

  final BaseItemDto track;
  static bool handles(BaseItemDto? item) =>
      item != null && YouTubeLibraryImport.isYouTube(item) && GetIt.instance<YouTubeLibraryImport>().available;

  @override
  Widget build(BuildContext context) {
    final importer = GetIt.instance<YouTubeLibraryImport>();
    return ValueListenableBuilder(
      valueListenable: importer.states,
      builder: (context, states, _) {
        final state = states[track.id.nativeId];
        return switch (state) {
          YouTubeImportState.uploading => IconButton(
            tooltip: "Sending to your library…",
            onPressed: null,
            icon: const SizedBox(
              width: 24,
              height: 24,
              child: Stack(
                alignment: Alignment.center,
                children: [CircularProgressIndicator(strokeWidth: 2), Icon(TablerIcons.cloud_upload, size: 14)],
              ),
            ),
          ),
          YouTubeImportState.added => IconButton(
            tooltip: "In your library",
            onPressed: null,
            icon: Icon(TablerIcons.cloud_check, color: Theme.of(context).colorScheme.primary),
          ),
          YouTubeImportState.waiting => IconButton(
            tooltip: "Waiting for the uploader — tap to retry now",
            icon: const Icon(TablerIcons.cloud_pause),
            onPressed: () => importer.send(track),
          ),
          YouTubeImportState.failed => IconButton(
            tooltip: "Couldn't add it — tap to retry",
            icon: Icon(TablerIcons.cloud_x, color: Theme.of(context).colorScheme.error),
            onPressed: () => importer.send(track),
          ),
          null => IconButton(
            tooltip: "Add to your library",
            icon: const Icon(TablerIcons.cloud_upload),
            onPressed: () => importer.send(track),
          ),
        };
      },
    );
  }
}
