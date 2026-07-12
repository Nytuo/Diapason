import 'package:diapason/components/SourcesSettingsScreen/source_form.dart';
import 'package:diapason/models/media_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class LoginSourceTypePage extends StatelessWidget {
  const LoginSourceTypePage({super.key, required this.onKindSelected});

  static const routeName = "login/source-type";

  final void Function(MediaSourceKind kind) onKindSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "Where's your music?",
            style: Theme.of(context).textTheme.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8.0),
          Text(
            "You can add more sources later — Diapason merges them all into one library.",
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32.0),

          for (final kind in MediaSourceKind.values.where((k) => k.isConfigurable))
            Card(
              margin: const EdgeInsets.only(bottom: 12.0),
              child: ListTile(
                leading: Icon(sourceKindPresentation(kind).icon, size: 32.0),
                title: Text(sourceKindPresentation(kind).label),
                subtitle: Text(_describe(kind)),
                trailing: const Icon(TablerIcons.chevron_right),
                onTap: () => onKindSelected(kind),
              ),
            ),
        ],
      ),
    );
  }

  static String _describe(MediaSourceKind kind) => switch (kind) {
    MediaSourceKind.jellyfin => "Connect to a Jellyfin server",
    MediaSourceKind.subsonic => "Navidrome, Airsonic, Gonic and friends",
    MediaSourceKind.plex => "Connect to a Plex Media Server",
    MediaSourceKind.local => "Music already on this device",
    MediaSourceKind.youtube => "",
  };
}

class LoginSourceFormPage extends StatelessWidget {
  const LoginSourceFormPage({super.key, required this.kind, required this.onSaved});

  static const routeName = "login/source-form";

  final MediaSourceKind kind;
  final void Function(MediaSourceConfig config) onSaved;

  String get _saveLabel => switch (kind) {
    MediaSourceKind.local => "Add folder",
    _ => "Connect",
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            sourceKindPresentation(kind).label,
            style: Theme.of(context).textTheme.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16.0),
          _SourceKindGuidance(kind: kind),
          const SizedBox(height: 24.0),
          SourceForm(kind: kind, saveLabel: _saveLabel, onSaved: onSaved),
        ],
      ),
    );
  }
}

class _SourceKindGuidance extends StatelessWidget {
  const _SourceKindGuidance({required this.kind});

  final MediaSourceKind kind;

  @override
  Widget build(BuildContext context) {
    return switch (kind) {
      MediaSourceKind.subsonic => Text(
        "Works with Navidrome, Airsonic, Gonic, and other Subsonic/OpenSubsonic servers. "
        "Enter the server's address and the same username and password you'd use to log in there.",
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      MediaSourceKind.plex => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Plex needs a token instead of a password:", style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8.0),
              Text(
                "1. Sign in to Plex in a browser, at app.plex.tv.\n"
                "2. Open any item, then its ⋮ menu, then \"Get Info\".\n"
                "3. Click \"View XML\" and copy the value after \"X-Plex-Token=\" in the "
                "address bar.",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      MediaSourceKind.local => Text(
        "Point Diapason at a folder of music files already on this device. "
        "No account, server or internet connection needed.",
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      MediaSourceKind.jellyfin || MediaSourceKind.youtube => const SizedBox.shrink(),
    };
  }
}
