import 'package:diapason/components/delete_prompts.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

class DeleteFromDeviceMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  final DownloadStub downloadStub;

  const DeleteFromDeviceMenuEntry({super.key, required this.downloadStub});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadsService = GetIt.instance<DownloadsService>();

    final DownloadItemStatus downloadStatus = ref.watch(downloadsService.statusProvider((downloadStub, null)));

    return Visibility(
      visible: downloadStatus.isRequired,
      child: MenuEntry(
        icon: Icons.delete_outlined,
        title: AppLocalizations.of(context)!.deleteFromTargetConfirmButton("device"),
        onTap: () async {
          await askBeforeDeleteDownloadFromDevice(context, downloadStub);
        },
      ),
    );
  }

  @override
  bool get isVisible => GetIt.instance<DownloadsService>().getStatus(downloadStub, null).isRequired;
}
