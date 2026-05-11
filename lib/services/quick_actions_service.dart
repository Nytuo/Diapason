import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/menus/output_menu.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/playback_history_screen.dart';
import 'package:finamp/screens/queue_restore_screen.dart';
import 'package:finamp/services/audio_service_helper.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/item_by_id_provider.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce/hive.dart';
import 'package:logging/logging.dart';

import 'item_helper.dart';

class QuickActionsService {
  QuickActionsService._();

  static final _quickActionsServiceLogger = Logger("QuickActionsService");

  static Future<void> handleAction(QuickActionConfig action, BuildContext context) async {
    final audioServiceHelper = GetIt.instance<AudioServiceHelper>();
    final queueService = GetIt.instance<QueueService>();

    _quickActionsServiceLogger.info("Handling quick action: $action");
    switch (action.action) {
      case FinampQuickActions.shuffleTracks:
        await audioServiceHelper.shuffleAll(onlyShowFavorites: FinampSettingsHelper.finampSettings.onlyShowFavorites);
        break;
      case FinampQuickActions.browseRecentQueues:
        await Navigator.pushNamed(context, QueueRestoreScreen.routeName);
        break;
      case FinampQuickActions.browsePlaybackHistory:
        await Navigator.pushNamed(context, PlaybackHistoryScreen.routeName);
        break;
      case FinampQuickActions.playRandomAlbum:
        await audioServiceHelper.playRandomItem(limitItemTypes: [BaseItemDtoType.album]);
        break;
      case FinampQuickActions.playRandomTrack:
        await audioServiceHelper.playRandomItem(limitItemTypes: [BaseItemDtoType.track]);
      case FinampQuickActions.playRandomFavoriteItem:
        await audioServiceHelper.playRandomItem(favoritesOnly: true);
        break;
      case FinampQuickActions.playMostRecentQueue:
        {
          final queuesBox = Hive.box<FinampStorableQueueInfo>("Queues");
          var queueMap = queuesBox.toMap();
          // queueMap.remove("latest");
          // var queueList = queueMap.values.toList();
          // queueList.sort((x, y) => y.creation - x.creation);
          final latestQueue = queueMap["latest"];
          if (latestQueue == null) {
            GlobalSnackbar.message((context) => "No recent queue found to play.*");
            return;
          }
          queueService.archiveSavedQueue();
          await queueService.loadSavedQueue(latestQueue).catchError(GlobalSnackbar.error);
        }
        break;
      case FinampQuickActions.configureOutput:
        await showOutputMenu(context: context);
        break;
      case FinampQuickActions.playSpecificItem:
        assert(action.itemId != null);
        final item = await GetIt.instance<ProviderContainer>().read(itemByIdProvider(action.itemId!).future);
        if (item == null) {
          GlobalSnackbar.message((_) => "Failed to load item '${action.itemName}*'");
        } else {
          await queueService.startPlayback(
            items: await loadChildTracks(item: PlayableBaseItem.defaultSort(item)),
            // TODO quick-action specific source?
            source: QueueItemSource.fromBaseItem(item),
            order: FinampPlaybackOrder.linear,
          );
        }
        _quickActionsServiceLogger.warning("Quick action $action is not implemented yet.");
        break;
      case FinampQuickActions.surpriseMe:
        await audioServiceHelper.startSurpriseMeMix();
        break;
    }
  }
}
