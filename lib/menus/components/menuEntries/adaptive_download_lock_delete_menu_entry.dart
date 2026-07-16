import 'package:diapason/menus/components/menuEntries/delete_from_device_menu_entry.dart';
import 'package:diapason/menus/components/menuEntries/download_menu_entry.dart';
import 'package:diapason/menus/components/menuEntries/lock_download_menu_entry.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

import 'menu_entry.dart';

class AdaptiveDownloadLockDeleteMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  final BaseItemDto baseItem;

  const AdaptiveDownloadLockDeleteMenuEntry({super.key, required this.baseItem});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadsService = GetIt.instance<DownloadsService>();

    final DownloadStub? downloadStub = _getStub();
    if (downloadStub == null) return const SizedBox.shrink();

    final DownloadItemStatus? downloadStatus = ref.watch(downloadsService.statusProvider((downloadStub, null)));

    if (!ref.watch(finampSettingsProvider.isOffline) && downloadStatus == DownloadItemStatus.notNeeded) {
      return DownloadMenuEntry(downloadStub: downloadStub);
    } else if (downloadStatus?.isRequired ?? false) {
      return DeleteFromDeviceMenuEntry(downloadStub: downloadStub);
    } else if (!ref.watch(finampSettingsProvider.isOffline) && (downloadStatus?.isIncidental ?? false)) {
      return LockDownloadMenuEntry(downloadStub: downloadStub);
    } else {
      return SizedBox.shrink();
    }
  }

  DownloadStub? _getStub() {
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    return switch (BaseItemDtoType.fromItem(baseItem)) {
      BaseItemDtoType.track => DownloadStub.fromItem(type: DownloadItemType.track, item: baseItem),
      BaseItemDtoType.artist || BaseItemDtoType.genre => library == null
          ? null
          : DownloadStub.fromFinampCollection(
              FinampCollection(type: FinampCollectionType.collectionWithLibraryFilter, library: library, item: baseItem),
            ),
      _ => DownloadStub.fromItem(type: DownloadItemType.collection, item: baseItem),
    };
  }

  @override
  bool get isVisible {
    final stub = _getStub();
    if (stub == null) return false;
    final DownloadItemStatus downloadStatus = GetIt.instance<DownloadsService>().getStatus(stub, null);

    return downloadStatus.isRequired || !FinampSettingsHelper.finampSettings.isOffline;
  }
}
