import 'dart:io';

import 'package:diapason/components/TagEditor/tag_editor_page.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/tag_edit_session.dart';
import 'package:diapason/services/tag_editor/tag_edit_target.dart';
import 'package:diapason/services/tag_editor/tag_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fixtures.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp("diapason_page_"));
  tearDown(() async => dir.delete(recursive: true));

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(TagEditSession session) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: TagEditorPage(item: session.item, sessionLoader: (_) async => session),
  );

  testWidgets("edits and saves a local track", (tester) async {
    tallView(tester);
    final file = File("${dir.path}/a.flac")..writeAsBytesSync(buildFlac());
    final item = BaseItemDto(id: const BaseItemId("loc~a"), name: "Song", type: "Audio");
    late TagEditSession session;
    await tester.runAsync(() async {
      await TagFile.write(
        file,
        AudioTags(
          values: {
            TagField.title: ["Song"],
            TagField.album: ["Old"],
          },
        ),
      );
      session = TagEditSession(item: item, tracks: [LocalFileTarget(item, file)]);
      await session.load();
    });

    await tester.pumpWidget(app(session));
    await tester.pumpAndSettle();

    expect(find.text("Edit tags"), findsOneWidget);
    expect(find.text("Changes are written into the audio files."), findsOneWidget);
    expect(find.widgetWithText(TextFormField, "Song"), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, "Old"), "New album");
    await tester.pump();
    expect(session.hasChanges, isTrue);

    await tester.runAsync(() async {
      expect(await session.save(), isEmpty);
    });
    await tester.runAsync(() async {
      expect((await TagFile.read(file))[TagField.album], "New album");
    });
  });

  testWidgets("read-only sources explain why and disable fields", (tester) async {
    final item = BaseItemDto(id: const BaseItemId("sub~1"), name: "Song", type: "Audio");
    final session = TagEditSession(item: item, tracks: [ReadOnlyTarget(item, TagReadOnlyReason.subsonic)]);
    await tester.runAsync(session.load);

    await tester.pumpWidget(app(session));
    await tester.pumpAndSettle();

    expect(find.textContaining("Subsonic API"), findsOneWidget);
    expect(find.text("Save"), findsNothing);
    final title = tester.widget<TextFormField>(find.widgetWithText(TextFormField, "Song"));
    expect(title.enabled, isFalse);
  });
}
