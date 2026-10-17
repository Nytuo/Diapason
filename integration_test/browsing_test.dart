import 'package:diapason/components/global_snackbar.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  installHarness();

  group('browsing the library', () {
    for (final view in [
      'Home',
      'Albums',
      'Artists',
      'Songs',
      'Genres',
      'Playlists',
      'Road trip',
      'Smart',
      'Discover',
    ]) {
      testApp('the $view view shows up', (tester) async {
        await launch(tester);
        await tester.waitFor(library, seconds: 30);
        await tester.tap(find.text(view).first, warnIfMissed: false);
        await tester.settle();
        expect(find.byType(Scaffold), findsWidgets);
        expect(find.textContaining('Error'), findsNothing);
      }, timeout: slow);
    }

    testApp('an album opens with its tracks, and a track has a context menu', (tester) async {
      await launch(tester);
      await openAlbums(tester);
      await tester.tap(find.text('First Album').first, warnIfMissed: false);
      await tester.waitFor(find.text('Opening'), seconds: 20);

      await tester.tap(find.text('Opening').first, buttons: kSecondaryButton, warnIfMissed: false);
      await tester.settle();
      await GlobalSnackbar.navigatorState!.maybePop();
      await tester.settle();
      await tester.longPress(find.text('Closing').first, warnIfMissed: false);
      await tester.settle();
      await GlobalSnackbar.navigatorState!.maybePop();
      await tester.settle();
    }, timeout: slow);

    testApp('an artist page lists their albums', (tester) async {
      await launch(tester);
      await tester.waitFor(library, seconds: 30);
      await tester.tap(find.text('Artists').first, warnIfMissed: false);
      await tester.settle();
      await tester.waitFor(find.text('Alpha Artist'), seconds: 20);
      await tester.tap(find.text('Alpha Artist').first, warnIfMissed: false);
      await tester.settle();
      await tester.waitFor(find.text('First Album'), seconds: 20);
    }, timeout: slow);

    testApp('searching finds songs, albums and artists', (tester) async {
      await launch(tester);
      await tester.waitFor(library, seconds: 30);
      final field = find.byType(TextField).first;
      await tester.enterText(field, 'Opening');
      await tester.settle();
      await tester.waitFor(find.text('Opening'), seconds: 20);
      expect(navidrome.calls('search3'), isNotEmpty, reason: 'it asked the server');
      await tester.enterText(field, '');
      await tester.settle();
    }, timeout: slow);
  });
}
