import 'package:diapason/components/LoginScreen/login_source_type_page.dart';
import 'package:diapason/components/SourcesSettingsScreen/source_form.dart';
import 'package:diapason/models/media_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group("LoginSourceTypePage", () {
    testWidgets("offers every kind of source", (tester) async {
      await tester.pumpWidget(_wrap(LoginSourceTypePage(onKindSelected: (_) {})));

      expect(find.text("Jellyfin"), findsOneWidget);
      expect(find.text("Subsonic / Navidrome"), findsOneWidget);
      expect(find.text("Plex"), findsOneWidget);
      expect(find.text("Local files"), findsOneWidget);
    });

    testWidgets("reports the chosen kind", (tester) async {
      MediaSourceKind? chosen;
      await tester.pumpWidget(_wrap(LoginSourceTypePage(onKindSelected: (kind) => chosen = kind)));

      await tester.tap(find.text("Plex"));
      await tester.pumpAndSettle();

      expect(chosen, MediaSourceKind.plex);
    });
  });

  group("SourceForm", () {
    testWidgets("asks Subsonic for a username and password", (tester) async {
      await tester.pumpWidget(
        _wrap(SourceForm(kind: MediaSourceKind.subsonic, onSaved: (_) {})),
      );

      expect(find.text("Server address"), findsOneWidget);
      expect(find.text("Username"), findsOneWidget);
      expect(find.text("Password"), findsOneWidget);
      // Plex authenticates with a token instead, so it must not appear here.
      expect(find.text("Plex token"), findsNothing);
    });

    testWidgets("asks Plex for a token instead of a password", (tester) async {
      await tester.pumpWidget(
        _wrap(SourceForm(kind: MediaSourceKind.plex, onSaved: (_) {})),
      );

      expect(find.text("Plex token"), findsOneWidget);
      expect(find.text("Password"), findsNothing);
    });

    testWidgets("a local source asks for a folder, not a server", (tester) async {
      await tester.pumpWidget(
        _wrap(SourceForm(kind: MediaSourceKind.local, onSaved: (_) {})),
      );

      expect(find.text("Server address"), findsNothing);
      expect(find.text("Choose a music folder"), findsOneWidget);
    });

    testWidgets("refuses to save until the required fields are filled", (tester) async {
      var saved = false;
      await tester.pumpWidget(
        _wrap(SourceForm(kind: MediaSourceKind.subsonic, onSaved: (_) => saved = true)),
      );

      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();

      expect(saved, isFalse);
      expect(find.text("A server address is required"), findsOneWidget);
      expect(find.text("A username is required"), findsOneWidget);
    });
  });
}
