import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/jellyfin_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/jellyfin_api_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:get_it/get_it.dart';

final ProviderFamily<bool, BaseItemDto> canDeleteFromServerProvider = Provider.autoDispose.family((
  ref,
  BaseItemDto item,
) {
  // we can't delete from server when offline
  bool offline = ref.watch(finampSettingsProvider.isOffline);
  if (offline) {
    return false;
  }
  var itemType = BaseItemDtoType.fromItem(item);
  var isPlaylist = itemType == BaseItemDtoType.playlist;
  bool deleteEnabled = ref.watch(finampSettingsProvider.allowDeleteFromServer);

  // always check if a playlist is deletable
  if (!deleteEnabled && !isPlaylist) {
    return false;
  }

  // do not bother checking server for item types known to not be deletable
  if (![BaseItemDtoType.album, BaseItemDtoType.playlist, BaseItemDtoType.track].contains(itemType)) {
    return false;
  }
  // Only Jellyfin can delete arbitrary items; other servers (e.g. Subsonic/Navidrome) only support playlists.
  if (!isPlaylist && GetIt.instance<BackendRegistry>().forItemId(item.id) is! JellyfinBackend) {
    return false;
  }
  bool? serverReturn = ref.watch(_canDeleteFromServerAsyncProvider(item.id)).value;
  if (serverReturn == null) {
    // fallback to allowing deletion even if the response is invalid, since the user might still be able to delete
    // worst case would be getting an error message when trying to delete
    return item.canDelete ?? true;
  } else {
    return serverReturn;
  }
});

final FutureProviderFamily<bool?, BaseItemId> _canDeleteFromServerAsyncProvider = FutureProvider.autoDispose.family((
  ref,
  BaseItemId id,
) {
  if (GetIt.instance<BackendRegistry>().forItemId(id) is! JellyfinBackend) {
    return Future.value(null);
  }
  return GetIt.instance<JellyfinApiHelper>()
      .getItemById(id)
      .then((response) {
        return response.canDelete;
      })
      .catchError((_) {
        return false;
      });
});

final ProviderFamily<bool, BaseItemDto> canEditPlaylistProvider = Provider.autoDispose.family((ref, BaseItemDto item) {
  var itemType = BaseItemDtoType.fromItem(item);
  assert(itemType == BaseItemDtoType.playlist, "canEditPlaylistProvider should only be used with playlists");

  // No need to check if offline, since we might support offline edits (which are synced on reconnect) at a later point, like adding a track to a playlist.
  // For now, the using widgets should still have this check in place.

  // do not bother checking server for item types known to not be editable
  if (![BaseItemDtoType.album, BaseItemDtoType.playlist, BaseItemDtoType.track].contains(itemType)) {
    return false;
  }
  bool? serverReturn = ref.watch(_canEditPlaylistAsyncProvider(item.id)).value;
  if (serverReturn == null) {
    // fallback to allowing deletion even if the response is invalid, since the user might still be able to delete
    // worst case would be getting an error message when trying to delete
    return true;
  } else {
    return serverReturn;
  }
});

final FutureProviderFamily<bool?, BaseItemId> _canEditPlaylistAsyncProvider = FutureProvider.autoDispose.family((
  ref,
  BaseItemId id,
) {
  if (GetIt.instance<BackendRegistry>().forItemId(id) is! JellyfinBackend) {
    return Future.value(null);
  }
  return GetIt.instance<JellyfinApiHelper>()
      .getPlaylistUser(id)
      .then((response) {
        return response.canEdit;
      })
      .catchError((_) {
        return false;
      });
});

final ProviderFamily<bool, BaseItemDto> canEditMetadataProvider = Provider.autoDispose.family((ref, BaseItemDto item) {
  // editing metadata while offline (e.g., through caching or edit queues) probably isn't a good idea
  bool offline = ref.watch(finampSettingsProvider.isOffline);
  if (offline) {
    return false;
  }
  if (GetIt.instance<BackendRegistry>().forItem(item) is! JellyfinBackend) {
    return true;
  }
  bool? serverReturn = ref.watch(_canEditMetadataAsyncProvider).value;
  return serverReturn ?? false;
});

final FutureProvider<bool> _canEditMetadataAsyncProvider = FutureProvider.autoDispose((ref) {
  return GetIt.instance<JellyfinApiHelper>()
      .getUser()
      .then((response) {
        return response.policy?.isAdministrator ?? false;
      })
      .catchError((_) {
        return false;
      });
});
