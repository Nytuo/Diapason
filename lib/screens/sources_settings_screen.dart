import 'package:diapason/components/SettingsScreen/logout_list_tile.dart';
import 'package:diapason/components/SourcesSettingsScreen/source_form.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/quick_connect_authorization_menu.dart';
import 'package:diapason/menus/server_sharing_menu.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/screens/login_screen.dart';
import 'package:diapason/services/backends/media_source_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

enum _JellyfinSourceAction { reconnect, shareServer, quickConnectAuthorization }

class SourcesSettingsScreen extends StatefulWidget {
  const SourcesSettingsScreen({super.key});

  static const routeName = "/settings/sources";

  @override
  State<SourcesSettingsScreen> createState() => _SourcesSettingsScreenState();
}

class _SourcesSettingsScreenState extends State<SourcesSettingsScreen> {
  MediaSourceService get _service => GetIt.instance<MediaSourceService>();

  List<MediaSourceConfig> _sources = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() => setState(() => _sources = _service.sources);

  bool get _hasJellyfinSource => _sources.any((s) => s.kind == MediaSourceKind.jellyfin);

  Future<void> _add() async {
    final offeredKinds = [
      if (!_hasJellyfinSource) MediaSourceKind.jellyfin,
      MediaSourceKind.subsonic,
      MediaSourceKind.plex,
      MediaSourceKind.local,
      MediaSourceKind.mpd,
    ];

    final kind = await showModalBottomSheet<MediaSourceKind>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text("Add a source", style: TextStyle(fontSize: 18.0, fontWeight: FontWeight.w500)),
            ),
            for (final kind in offeredKinds)
              ListTile(
                leading: Icon(sourceKindPresentation(kind).icon),
                title: Text(sourceKindPresentation(kind).label),
                onTap: () => Navigator.of(context).pop(kind),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;

    if (kind == MediaSourceKind.jellyfin) {
      await Navigator.of(context).push<void>(MaterialPageRoute(builder: (context) => const LoginScreen(jellyfinOnly: true)));
      await _service.syncJellyfinSource();
      if (!mounted) return;
      _refresh();
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (context) => EditSourceScreen(kind: kind)),
    );
    _refresh();
  }

  Future<void> _edit(MediaSourceConfig source) async {
    if (source.kind == MediaSourceKind.jellyfin) {
      await _showJellyfinSourceActions(source);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (context) => EditSourceScreen(kind: source.kind, existing: source)),
    );
    _refresh();
  }

  Future<void> _showJellyfinSourceActions(MediaSourceConfig source) async {
    final action = await showModalBottomSheet<_JellyfinSourceAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(source.name, style: const TextStyle(fontSize: 18.0, fontWeight: FontWeight.w500)),
            ),
            ListTile(
              leading: const Icon(TablerIcons.refresh),
              title: const Text("Reconnect"),
              subtitle: const Text("Server discovery, users, Quick Connect"),
              onTap: () => Navigator.of(context).pop(_JellyfinSourceAction.reconnect),
            ),
            ListTile(
              leading: const Icon(TablerIcons.access_point),
              title: Text(AppLocalizations.of(context)!.serverSharingMenuButtonTitle),
              onTap: () => Navigator.of(context).pop(_JellyfinSourceAction.shareServer),
            ),
            ListTile(
              leading: const Icon(TablerIcons.lock_bolt),
              title: Text(AppLocalizations.of(context)!.quickConnectAuthorizationMenuButtonTitle),
              onTap: () => Navigator.of(context).pop(_JellyfinSourceAction.quickConnectAuthorization),
            ),
            const Divider(),
            const LogoutListTile(),
          ],
        ),
      ),
    );
    if (!mounted) return;

    switch (action) {
      case _JellyfinSourceAction.reconnect:
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (context) => const LoginScreen(jellyfinOnly: true)),
        );
        await _service.syncJellyfinSource();
        if (!mounted) return;
        _refresh();
      case _JellyfinSourceAction.shareServer:
        await showServerSharingPanel(context: context);
      case _JellyfinSourceAction.quickConnectAuthorization:
        await showQuickConnectAuthorizationMenu(context: context);
      case null:
    }
  }

  Future<void> _remove(MediaSourceConfig source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Remove ${source.name}?"),
        content: const Text(
          "Its music will disappear from your library. Anything you downloaded from it stays on this device "
          "until you delete it.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text("Remove")),
        ],
      ),
    );
    if (confirmed != true) return;

    await _service.removeSource(source.sourceId);
    _refresh();
  }

  Future<void> _setEnabled(MediaSourceConfig source, bool enabled) async {
    source.enabled = enabled;
    await _service.updateSource(source);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Sources")),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(TablerIcons.plus),
        label: const Text("Add source"),
      ),
      body: _sources.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: Text(
                  "No sources yet.\nAdd a Jellyfin, Plex or Subsonic server, or a folder of local files.",
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88.0),
              itemCount: _sources.length,
              itemBuilder: (context, index) {
                final source = _sources[index];
                final presentation = sourceKindPresentation(source.kind);
                final subtitle = source.kind == MediaSourceKind.local ? source.localPath : source.baseUrl;

                return ListTile(
                  leading: Icon(presentation.icon),
                  title: Text(source.name),
                  subtitle: Text(
                    subtitle.isEmpty ? presentation.label : "${presentation.label} · $subtitle",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _edit(source),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(value: source.enabled, onChanged: (value) => _setEnabled(source, value)),
                      IconButton(
                        icon: const Icon(TablerIcons.trash),
                        onPressed: () => _remove(source),
                        tooltip: "Remove",
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class EditSourceScreen extends StatelessWidget {
  const EditSourceScreen({super.key, required this.kind, this.existing});

  final MediaSourceKind kind;
  final MediaSourceConfig? existing;

  @override
  Widget build(BuildContext context) {
    final presentation = sourceKindPresentation(kind);

    return Scaffold(
      appBar: AppBar(title: Text(existing == null ? "Add ${presentation.label}" : existing!.name)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: SourceForm(
          kind: kind,
          existing: existing,
          saveLabel: existing == null ? "Add" : "Save",
          onSaved: (config) async {
            final service = GetIt.instance<MediaSourceService>();
            if (existing == null) {
              await service.addSource(config);
            } else {
              await service.updateSource(config);
            }
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }
}
