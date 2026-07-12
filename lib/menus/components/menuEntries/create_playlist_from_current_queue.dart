import 'package:diapason/components/AddToPlaylistScreen/new_playlist_dialog.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/menus/playlist_actions_menu.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class CreatePlaylistFromCurrentQueueMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const CreatePlaylistFromCurrentQueueMenuEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueService = GetIt.instance<QueueService>();

    return MenuEntry(
      icon: TablerIcons.list_tree,
      title: AppLocalizations.of(context)!.createPlaylistFromCurrentQueue,
      onTap: () async {
        if (context.mounted) Navigator.pop(context);
        final currentQueue = queueService.getQueue();

        await showPlaylistActionsMenu(
          context: context,
          items: currentQueue.fullQueue.where((item) => item.baseItem != null).map((item) {
            return item.baseItem!;
          }).toList(),
        );
      },
    );
  }

  @override
  bool get isVisible => true;
}
