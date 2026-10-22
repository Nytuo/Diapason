import 'package:diapason/components/AlbumScreen/download_dialog.dart';
import 'package:diapason/components/MusicScreen/youtube_upload_button.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/uploader/youtube_library_import.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

import '../../../components/confirmation_prompt_dialog.dart';

class DownloadMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  final DownloadStub downloadStub;
  final String? warningMessage;

  const DownloadMenuEntry({super.key, required this.downloadStub, this.warningMessage});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadsService = GetIt.instance<DownloadsService>();

    final DownloadItemStatus? downloadStatus = ref.watch(downloadsService.statusProvider((downloadStub, null)));
    final toLibrary = downloadStub.type == DownloadItemType.track && YouTubeUploadButton.handles(downloadStub.baseItem);

    return Visibility(
      visible: !ref.watch(finampSettingsProvider.isOffline) && downloadStatus == DownloadItemStatus.notNeeded,
      child: MenuEntry(
        icon: toLibrary ? TablerIcons.cloud_upload : TablerIcons.download,
        title: toLibrary ? "Add to your library" : AppLocalizations.of(context)!.downloadItem,
        onTap: () async {
          if (toLibrary) {
            Navigator.pop(context);
            await GetIt.instance<YouTubeLibraryImport>().send(downloadStub.baseItem!);
            return;
          }
          if (warningMessage != null) {
            final confirmed = await showDialog<bool?>(
              context: context,
              builder: (context) => ConfirmationPromptDialog(
                promptText: warningMessage!,
                confirmButtonText: AppLocalizations.of(context)!.addButtonLabel,
              ),
            );
            if ((confirmed ?? false) && context.mounted) {
              await DownloadDialog.show(context, downloadStub, null);
            }
          } else {
            await DownloadDialog.show(context, downloadStub, null);
          }
          if (context.mounted) {
            Navigator.pop(context);
          }
        },
      ),
    );
  }

  @override
  bool get isVisible =>
      GetIt.instance<DownloadsService>().getStatus(downloadStub, null) == DownloadItemStatus.notNeeded &&
      !FinampSettingsHelper.finampSettings.isOffline;
}
