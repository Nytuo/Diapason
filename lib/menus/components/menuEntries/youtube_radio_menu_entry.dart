import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/discovery/youtube_discover_service.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class YouTubeRadioMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  final BaseItemDto baseItem;

  const YouTubeRadioMenuEntry({super.key, required this.baseItem});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuEntry(
      icon: TablerIcons.brand_youtube,
      title: "Discover with YouTube",
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        messenger.showSnackBar(SnackBar(content: Text("Finding music like '${baseItem.name ?? "this track"}'…")));
        try {
          final similar = await GetIt.instance<YouTubeDiscoverService>().radioFor(baseItem);
          if (similar.isEmpty) {
            messenger.showSnackBar(const SnackBar(content: Text("YouTube had nothing to suggest for that track.")));
            return;
          }
          await GetIt.instance<QueueService>().startPlayback(
            items: [baseItem, ...similar],
            source: QueueItemSource(
              type: QueueItemSourceType.unknown,
              name: QueueItemSourceName(
                type: QueueItemSourceNameType.preTranslated,
                pretranslatedName: "YouTube Discover · ${baseItem.name ?? ""}".trim(),
              ),
              id: baseItem.id,
            ),
          );
        } catch (e, stack) {
          messenger.showSnackBar(
            SnackBar(
              content: Text("Couldn't start discover. ${FriendlyError.reportGlobal("YouTube discover", e, stack)}"),
            ),
          );
        }
      },
    );
  }

  @override
  bool get isVisible => isYouTubeAvailable;
}
