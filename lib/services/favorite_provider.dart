import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:get_it/get_it.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../components/global_snackbar.dart';
import '../models/jellyfin_models.dart';
import 'downloads_service.dart';
import 'feedback_helper.dart';
import 'finamp_settings_helper.dart';

part 'favorite_provider.g.dart';

@riverpod
class IsFavorite extends _$IsFavorite {
  bool _changed = false;
  Future<void>? _initializing;

  @override
  bool build(BaseItemDto? item) {
    if (item == null) {
      return false;
    }
    ref.listen(finampSettingsProvider.isOffline, (_, value) {
      if (!_changed && value == false) {
        // If we have not had updateFavorite run and are moving from offline to
        // online, invalidate to fetch latest data from server.
        ref.invalidateSelf();
      }
    });

    if ((item.finampOffline ?? false) || item.userData?.isFavorite == null) {
      if (!FinampSettingsHelper.finampSettings.isOffline) {
        // Fetch the latest value from the server to replace the request's default value
        // as soon as possible.
        _initializing = Future.sync(() async {
          try {
            final newItem = await GetIt.instance<AggregateBackend>().getItemById(item.id);
            if (!_changed && newItem != null) {
              state = newItem.userData?.isFavorite ?? false;
            }
          } catch (e) {
            GlobalSnackbar.error(e);
          }
        });
      }
      // The favorites status in offline items is unreliable, use isFavorite instead
      // if possible.
      return GetIt.instance<DownloadsService>().isFavorite(item) ?? item.userData?.isFavorite ?? false;
    } else {
      return item.userData?.isFavorite ?? false;
    }
  }

  bool updateFavorite(bool isFavorite) {
    assert(item != null);
    final isOffline = FinampSettingsHelper.finampSettings.isOffline;
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    final queueService = GetIt.instance<QueueService>();
    if (isOffline) {
      FeedbackHelper.feedback(FeedbackType.error);
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.notAvailableInOfflineMode);
      return state;
    }

    var oldState = state;
    // Once the favorite has been toggled, any existing BaseItemDtos may be out
    // of date, so we can never safely re-create the widget from a DefaultValue
    // and must keep it alive.
    ref.keepAlive();
    _changed = true;

    Future.sync(() async {
      try {
        final applied = await GetIt.instance<AggregateBackend>().setFavorite(item!, isFavorite: isFavorite);
        if (!applied) {
          state = oldState;
          GlobalSnackbar.message((context) => "This source doesn't support favorites");
          return;
        }
        state = isFavorite;

        FeedbackHelper.feedback(FeedbackType.heavy);
      } catch (e) {
        state = oldState;
        GlobalSnackbar.error(e);
      }
    });
    state = isFavorite;
    // If the current track is the one being toggled, update the playback state (and media notification)
    if (item!.id == queueService.getCurrentTrack()?.baseItem?.id) {
      audioHandler.refreshPlaybackStateAndMediaNotification();
    }
    return state;
  }

  void updateState(bool isFavorite) {
    if (state != isFavorite) {
      // cache new state to override existing BaseItemDto data from queue
      _changed = true;
      ref.keepAlive();
    }
    state = isFavorite;
  }

  void toggleFavorite() async {
    if (_initializing != null) {
      await _initializing;
    }
    updateFavorite(!state);
  }
}
