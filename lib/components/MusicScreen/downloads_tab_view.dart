import 'package:diapason/components/DownloadsErrorScreen/download_error_list.dart';
import 'package:diapason/components/DownloadsScreen/downloaded_items_list.dart';
import 'package:diapason/components/DownloadsScreen/downloads_overview.dart';
import 'package:diapason/components/DownloadsScreen/repair_downloads_button.dart';
import 'package:diapason/components/DownloadsScreen/sync_downloads_button.dart';
import 'package:diapason/components/padded_custom_scrollview.dart';
import 'package:diapason/components/stream_prefetch_bar.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

class DownloadsTabView extends StatelessWidget {
  const DownloadsTabView({super.key});

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final downloadsService = GetIt.instance<DownloadsService>();

    final active = Rx.combineLatest4<
      List<DownloadStub>,
      List<DownloadStub>,
      List<DownloadStub>,
      List<DownloadStub>,
      List<List<DownloadStub>>
    >(
      downloadsService.getDownloadList(DownloadItemState.syncFailed),
      downloadsService.getDownloadList(DownloadItemState.failed),
      downloadsService.getDownloadList(DownloadItemState.downloading),
      downloadsService.getDownloadList(DownloadItemState.enqueued),
      (syncFailed, failed, downloading, enqueued) => [syncFailed, failed, downloading, enqueued],
    );

    return StreamBuilder<List<List<DownloadStub>>>(
      stream: active,
      builder: (context, snapshot) {
        final lists = snapshot.data ?? const [<DownloadStub>[], [], [], []];
        final hasActive = lists.any((list) => list.isNotEmpty);

        return PaddedCustomScrollview(
          slivers: [
            SliverList(
              delegate: SliverChildListDelegate([
                const StreamPrefetchBar(),
                const Padding(padding: EdgeInsets.fromLTRB(8, 8, 8, 0), child: DownloadsOverview()),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [SyncDownloadsButton(), RepairDownloadsButton()],
                  ),
                ),
                const Divider(),
              ]),
            ),

            if (hasActive) DownloadedItemsTitle(title: localizations.activeDownloadsTitle),
            if (lists[2].isNotEmpty) DownloadErrorList(state: DownloadItemState.downloading, children: lists[2]),
            if (lists[3].isNotEmpty) DownloadErrorList(state: DownloadItemState.enqueued, children: lists[3]),
            if (lists[1].isNotEmpty) DownloadErrorList(state: DownloadItemState.failed, children: lists[1]),
            if (lists[0].isNotEmpty) DownloadErrorList(state: DownloadItemState.syncFailed, children: lists[0]),

            DownloadedItemsTitle(title: localizations.specialDownloads),
            const DownloadedItemsList(type: DownloadsScreenCategory.special),
            DownloadedItemsTitle(title: localizations.libraryDownloads),
            const DownloadedItemsList(type: DownloadsScreenCategory.library),
            DownloadedItemsTitle(title: localizations.playlists),
            const DownloadedItemsList(type: DownloadsScreenCategory.playlists),
            DownloadedItemsTitle(title: localizations.artists),
            const DownloadedItemsList(type: DownloadsScreenCategory.artists),
            DownloadedItemsTitle(title: localizations.albums),
            const DownloadedItemsList(type: DownloadsScreenCategory.albums),
            DownloadedItemsTitle(title: localizations.genres),
            const DownloadedItemsList(type: DownloadsScreenCategory.genres),
            DownloadedItemsTitle(title: localizations.tracks),
            const DownloadedItemsList(type: DownloadsScreenCategory.tracks),
          ],
        );
      },
    );
  }
}
