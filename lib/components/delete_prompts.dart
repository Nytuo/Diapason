import 'package:diapason/components/confirmation_prompt_dialog.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/screens/album_screen.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../models/jellyfin_models.dart';

Future<void> askBeforeDeleteDownloadFromDevice(BuildContext context, DownloadStub stub, {VoidCallback? refresh}) async {
  String type = stub.baseItemType.name;
  await showDialog<void>(
    context: context,
    builder: (context) => ConfirmationPromptDialog(
      promptText: AppLocalizations.of(context)!.deleteFromTargetDialogText("", "device", type),
      confirmButtonText: AppLocalizations.of(context)!.deleteFromTargetConfirmButton("device"),
      onConfirmed: () async {
        try {
          await GetIt.instance<DownloadsService>().deleteDownload(stub: stub);
          GlobalSnackbar.message((scaffold) => AppLocalizations.of(scaffold)!.itemDeletedSnackbar("device", type));

          if (context.mounted && FinampSettingsHelper.finampSettings.isOffline) {
            Navigator.of(context).popUntil((route) {
              return route.settings.name !=
                      null // unnamed dialog
                      &&
                  route.settings.name != AlbumScreen.routeName; // albums screen
            });
          }
        } catch (err) {
          GlobalSnackbar.error(err);
        } finally {
          refresh != null ? refresh() : null;
        }
      },
      centerText: true,
    ),
  );
}

Future<void> askBeforeDeleteFromServerAndDevice(
  BuildContext context,
  DownloadStub stub, {
  VoidCallback? refresh,
  bool popIt = false,
}) async {
  DownloadItemStatus status = GetIt.instance<DownloadsService>().getStatus(stub, null);
  String type = stub.baseItemType.name;

  final downloadsService = GetIt.instance<DownloadsService>();

  final deleteType = status.toDeleteType();

  await showDialog<void>(
    context: context,
    builder: (_) => ConfirmationPromptDialog(
      promptText: AppLocalizations.of(context)!.deleteFromTargetDialogText(deleteType.textForm, "server", type),
      confirmButtonText: AppLocalizations.of(context)!.deleteFromTargetConfirmButton("server"),
      onConfirmed: () async {
        try {
          final backend = GetIt.instance<BackendRegistry>().forItemId(BaseItemId(stub.id));
          if (backend == null) throw StateError("No source is registered for item '${stub.id}'.");
          await backend.deleteItem(BaseItemId(stub.id), isPlaylist: stub.baseItemType == BaseItemDtoType.playlist);
          GlobalSnackbar.message((scaffold) => AppLocalizations.of(scaffold)!.itemDeletedSnackbar("server", type));

          if (status.isRequired) {
            await downloadsService.deleteDownload(stub: stub);
            GlobalSnackbar.message((scaffold) => AppLocalizations.of(scaffold)!.itemDeletedSnackbar("device", type));
          }

          if (context.mounted) {
            if (popIt) {
              Navigator.of(context).popUntil((route) {
                return route.settings.name !=
                        null // unnamed dialog
                        &&
                    route.settings.name != AlbumScreen.routeName; // albums screen
              });
            }
          }
        } catch (err) {
          GlobalSnackbar.error(err);
        } finally {
          refresh != null ? refresh() : null;
        }
      },
      centerText: true,
    ),
  );
}
