import 'dart:async';

import 'package:diapason/screens/sources_settings_screen.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/services/backends/media_source_service.dart';
import 'package:diapason/models/media_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/harness.dart';

void main() {
  installHarness();

  group('sources', () {
    MediaSourceService service() => GetIt.instance<MediaSourceService>();

    Future<void> openSources(WidgetTester tester) async {
      GlobalSnackbar.navigatorState!.pushNamed(SourcesSettingsScreen.routeName);
      await tester.settle();
      expect(find.text('Sources'), findsWidgets);
    }

    Future<void> addSource(WidgetTester tester, String kindLabel, Map<String, String> fields) async {
      await tester.tap(find.text('Add source'));
      await tester.settle();
      await tester.tap(find.text(kindLabel).last);
      await tester.settle();
      for (final entry in fields.entries) {
        await tester.enterText(find.widgetWithText(TextFormField, entry.key), entry.value);
      }
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.waitUntil(
        () => find.widgetWithText(TextFormField, 'Name (optional)').evaluate().isEmpty,
        what: 'the add form closing',
      );
      await tester.settle();
    }

    testApp('the list shows the Navidrome server that was connected', (tester) async {
      await launch(tester);
      await openSources(tester);

      expect(service().sources.where((s) => s.kind == MediaSourceKind.subsonic), hasLength(1));
      expect(find.textContaining('Subsonic / Navidrome'), findsWidgets);
      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
    });

    testApp('an MPD daemon can be added, and its albums show up in the library', (tester) async {
      await launch(tester);
      await openSources(tester);

      await addSource(tester, 'MPD', {'Name (optional)': 'Living room', 'Server address': '127.0.0.1:${mpd.port}'});

      expect(find.text('Living room'), findsOneWidget);
      expect(service().sources.where((s) => s.kind == MediaSourceKind.mpd), hasLength(1));
      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
      await openAlbums(tester);
      await tester.waitFor(find.text('Mpd Album'), seconds: 30);
      expect(mpd.commands, contains('list album group albumartist'));
    }, timeout: slow);

    testApp('a Plex server can be added too', (tester) async {
      await launch(tester);
      await openSources(tester);

      await addSource(tester, 'Plex', {
        'Name (optional)': 'Plex box',
        'Server address': 'http://127.0.0.1:${plex.port}',
        'Plex token': 'token',
      });

      expect(find.text('Plex box'), findsOneWidget);
      expect(service().sources.map((s) => s.kind), containsAll([MediaSourceKind.subsonic, MediaSourceKind.plex]));
      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
    }, timeout: slow);

    testApp('a source can be switched off and on again', (tester) async {
      await launch(tester);
      await openSources(tester);
      final mpdSource = service().sources.firstWhere((s) => s.kind == MediaSourceKind.mpd);

      final toggle = find.descendant(of: find.widgetWithText(ListTile, 'Living room'), matching: find.byType(Switch));
      await tester.tap(toggle);
      await tester.settle();
      expect(service().sources.firstWhere((s) => s.sourceId == mpdSource.sourceId).enabled, isFalse);

      await tester.tap(toggle);
      await tester.settle();
      expect(service().sources.firstWhere((s) => s.sourceId == mpdSource.sourceId).enabled, isTrue);
      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
    }, timeout: slow);

    testApp('removing asks first; "Cancel" keeps it and "Remove" drops it', (tester) async {
      await launch(tester);
      await openSources(tester);
      final trash = find.descendant(of: find.widgetWithText(ListTile, 'Plex box'), matching: find.byTooltip('Remove'));

      await tester.tap(trash);
      await tester.settle();
      expect(find.text('Remove Plex box?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.settle();
      expect(find.text('Plex box'), findsOneWidget);

      await tester.tap(trash);
      await tester.settle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.settle();
      expect(find.text('Plex box'), findsNothing);
      expect(service().sources.where((s) => s.kind == MediaSourceKind.plex), isEmpty);

      // And the MPD daemon, so later tests see only the Navidrome library again.
      await tester.tap(
        find.descendant(of: find.widgetWithText(ListTile, 'Living room'), matching: find.byTooltip('Remove')),
      );
      await tester.settle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.settle();
      expect(service().sources.where((s) => s.kind == MediaSourceKind.mpd), isEmpty);
      GlobalSnackbar.navigatorState!.pop();
      await tester.settle();
    }, timeout: slow);
  });
}
