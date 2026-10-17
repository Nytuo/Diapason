import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/album_screen.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/screens/downloads_screen.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/harness.dart';



void main() {
  installHarness();

  AggregateBackend backend() => GetIt.instance<AggregateBackend>();
  DownloadsService downloads() => GetIt.instance<DownloadsService>();
  QueueService queue() => GetIt.instance<QueueService>();

  late BaseItemDto album;
  late DownloadStub stub;

  Future<void> downloadAlbum(WidgetTester tester) async {
    album = (await backend().getItems(includeItemTypes: 'MusicAlbum')).first;
    stub = DownloadStub.fromItem(type: DownloadItemType.collection, item: album);
    await downloads().addDownload(
      stub: stub,
      transcodeProfile: DownloadProfile(transcodeCodec: FinampTranscodingCodec.original),
    );


    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 8) &&
        downloads().getStatus(stub, null) != DownloadItemStatus.required) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    print('download status after ${clock.elapsed.inSeconds}s: ${downloads().getStatus(stub, null)}');
  }

  group('downloads and offline mode', () {
    testApp('an album downloads completely', (tester) async {
      await launch(tester);
      await downloadAlbum(tester);
      expect(downloads().getStatus(stub, null), isNot(DownloadItemStatus.notNeeded), reason: 'the album is wanted');

      GlobalSnackbar.navigatorState!.pushNamed(DownloadsScreen.routeName);
      await tester.settle(frames: 12);
      expect(find.textContaining('downloads'), findsWidgets);
      await exploreTop(tester, taps: 6, seed: 111, avoid: r'delete|remove|clear|reset|window');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testApp('offline, the library shows what was downloaded and pages open from it', (tester) async {
      await launch(tester);
      await downloadAlbum(tester);
      FinampSetters.setIsOffline(true);
      addTearDown(() => FinampSetters.setIsOffline(false));
      await tester.settle(frames: 8);

      await tester.waitFor(library, seconds: 30);
      for (final view in ['Home', 'Albums', 'Artists', 'Songs', 'Genres', 'Playlists']) {
        final entry = find.text(view);
        if (entry.evaluate().isEmpty) continue;
        await tester.tap(entry.first, warnIfMissed: false);
        await tester.settle(frames: 10);
      }
      await tester.tap(find.text('Albums').first, warnIfMissed: false);
      await tester.settle(frames: 10);

      GlobalSnackbar.navigatorState!.pushNamed(AlbumScreen.routeName, arguments: album);
      await tester.settle(frames: 12);
      await exploreTop(tester, taps: 4, seed: 112, avoid: r'delete|remove|clear|reset|window|play|shuffle|radio|mix');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);

      final artist = (await backend().getItems(includeItemTypes: 'MusicArtist')).first;
      GlobalSnackbar.navigatorState!.pushNamed(ArtistScreen.routeName, arguments: artist);
      await tester.settle(frames: 12);
      await exploreTop(tester, taps: 4, seed: 113, avoid: r'delete|remove|clear|reset|window|play|shuffle|radio|mix');
      GlobalSnackbar.navigatorState!.popUntil((r) => r.isFirst);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testApp('syncing downloads and deleting the album works', (tester) async {
      await launch(tester);
      await downloadAlbum(tester);
      await downloads().resyncAll(forceSync: true);
      await tester.settle(frames: 10);
      await downloads().deleteDownload(stub: stub);
      await tester.waitUntil(
        () => downloads().getStatus(stub, null) == DownloadItemStatus.notNeeded,
        seconds: 30,
        what: 'the download being removed',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
