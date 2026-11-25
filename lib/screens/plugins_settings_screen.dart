import 'package:diapason/screens/desktop/desktop_router.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/plugins/plugin_catalog.dart';
import 'package:diapason/services/plugins/plugin_host.dart';
import 'package:diapason/services/plugins/plugin_manager.dart';
import 'package:diapason/services/plugins/plugin_manifest.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = Logger("PluginsSettingsScreen");

/// Settings > Plugins: installed plugins, catalogs, and installing from a file.
class PluginsSettingsScreen extends StatefulWidget {
  const PluginsSettingsScreen({super.key});

  static const routeName = "/settings/plugins";

  @override
  State<PluginsSettingsScreen> createState() => _PluginsSettingsScreenState();
}

class _PluginsSettingsScreenState extends State<PluginsSettingsScreen> {
  PluginManager get _manager => GetIt.instance<PluginManager>();

  final _catalogs = <String, Future<PluginCatalog>>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadCatalogs();
  }

  void _loadCatalogs() {
    _catalogs.clear();
    for (final url in _manager.catalogUrls) {
      _catalogs[url] = _manager.fetchCatalog(url);
    }
  }

  void _snack(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _reason(Object error) =>
      error is PluginInstallException ? error.message : FriendlyError.report(_log, "Plugin install", error);

  Future<void> _run(Future<PendingInstall> Function() prepare) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final pending = await prepare();
      if (!mounted) return;
      final approved = await _showPluginApproval(
        context,
        manifest: pending.manifest,
        permissions: pending.permissionsToApprove,
        mode: pending.isUpdate ? _ApprovalMode.update : _ApprovalMode.install,
      );
      if (!approved) return;
      await _manager.install(pending, granted: [...?pending.existing?.record.granted, ...pending.permissionsToApprove]);
      _snack(
        pending.isUpdate
            ? l10n.pluginsUpdatedMessage(pending.manifest.name)
            : l10n.pluginsInstalledMessage(pending.manifest.name),
      );
    } catch (e) {
      _snack(l10n.pluginsInstallFailed(_reason(e)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installFromFile() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ["zip"]);
    final path = files.firstOrNull?.path;
    if (path == null) return;
    await _run(() async => _manager.prepare(Uint8List.fromList(await File(path).readAsBytes())));
  }

  Future<void> _addCatalog() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(l10n.pluginsAddCatalog),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: l10n.pluginsCatalogUrl, hintText: "https://", errorText: error),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
              ),
              FilledButton(
                onPressed: () {
                  final normalized = PluginCatalog.normalizeUrl(controller.text);
                  if (normalized == null) {
                    setDialogState(() => error = l10n.pluginsInvalidCatalogUrl);
                  } else {
                    Navigator.pop(context, normalized);
                  }
                },
                child: Text(l10n.pluginsAddCatalog),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    if (url == null) return;
    await _manager.setCatalogUrls([..._manager.catalogUrls, url]);
    setState(() => _catalogs[url] = _manager.fetchCatalog(url));
  }

  Future<void> _removeCatalog(String url) async {
    await _manager.setCatalogUrls(_manager.catalogUrls.where((u) => u != url).toList());
    setState(() => _catalogs.remove(url));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.pluginsTitle),
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
      ),
      body: ListenableBuilder(
        listenable: _manager,
        builder: (context, _) {
          final installed = _manager.installed;
          return RefreshIndicator(
            onRefresh: () async {
              setState(_loadCatalogs);
              await Future.wait(_catalogs.values.map((f) => f.then((_) {}, onError: (_) {})));
            },
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(l10n.pluginsSandboxNote, style: theme.textTheme.bodySmall),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _installFromFile,
                        icon: const Icon(TablerIcons.file_zip),
                        label: Text(l10n.pluginsInstallFromFile),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _addCatalog,
                        icon: const Icon(TablerIcons.world_plus),
                        label: Text(l10n.pluginsAddCatalog),
                      ),
                    ],
                  ),
                ),
                _Header(l10n.pluginsInstalled),
                if (installed.isEmpty)
                  ListTile(title: Text(l10n.pluginsNoneInstalled, style: theme.textTheme.bodyMedium)),
                for (final plugin in installed)
                  ListTile(
                    leading: Icon(
                      plugin.manifest.runtime == PluginRuntimeKind.wasm ? TablerIcons.cpu : TablerIcons.plug,
                    ),
                    title: Text(plugin.manifest.name),
                    subtitle: Text(
                      "${plugin.manifest.version} · ${_statusLabel(l10n, plugin.status)}",
                      style: plugin.status == PluginStatus.failed || plugin.status == PluginStatus.needsApproval
                          ? TextStyle(color: theme.colorScheme.error)
                          : null,
                    ),
                    trailing: Switch(value: plugin.record.enabled, onChanged: (value) => _toggle(plugin, value)),
                    onTap: () =>
                        DesktopRouter.pushPage<void>(context, (_) => PluginDetailsScreen(pluginId: plugin.manifest.id)),
                  ),
                _Header(l10n.pluginsCatalogs),
                if (_catalogs.isEmpty) ListTile(title: Text(l10n.pluginsNoCatalogs, style: theme.textTheme.bodyMedium)),
                for (final entry in _catalogs.entries) _catalogSection(context, entry.key, entry.value),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _toggle(InstalledPlugin plugin, bool enabled) async {
    var approve = false;
    if (enabled && plugin.unapproved.isNotEmpty) {
      approve = await _showPluginApproval(
        context,
        manifest: plugin.manifest,
        permissions: plugin.unapproved,
        mode: _ApprovalMode.enable,
      );
      if (!approve) return;
    }
    await _manager.setEnabled(plugin.manifest.id, enabled, approve: approve);
  }

  Widget _catalogSection(BuildContext context, String url, Future<PluginCatalog> future) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return FutureBuilder<PluginCatalog>(
      future: future,
      builder: (context, snapshot) {
        final catalog = snapshot.data;
        final header = ListTile(
          dense: true,
          title: Text(catalog?.name ?? Uri.parse(url).host, style: theme.textTheme.titleSmall),
          subtitle: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: l10n.pluginsRemoveCatalog,
            icon: const Icon(TablerIcons.trash),
            onPressed: () => _removeCatalog(url),
          ),
        );
        if (snapshot.connectionState != ConnectionState.done) {
          return Column(children: [header, const LinearProgressIndicator()]);
        }
        if (snapshot.hasError) {
          final error = snapshot.error!;
          return Column(
            children: [
              header,
              ListTile(
                title: Text(
                  l10n.pluginsCatalogFailed(
                    error is PluginInstallException ? error.message : FriendlyError.message(error),
                  ),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
          );
        }
        final updates = {
          for (final u in _manager.updatesIn([catalog!])) u.entry.id: u,
        };
        return Column(
          children: [
            header,
            if (catalog.entries.isEmpty) ListTile(title: Text(l10n.pluginsCatalogEmpty)),
            for (final entry in catalog.entries)
              ListTile(
                title: Text(entry.name),
                subtitle: Text(
                  [
                    if (entry.author.isNotEmpty) l10n.pluginsVersionBy(entry.version, entry.author) else entry.version,
                    if (entry.description.isNotEmpty) entry.description,
                    ?entry.problem,
                  ].join("\n"),
                ),
                isThreeLine: entry.description.isNotEmpty || entry.problem != null,
                trailing: _catalogAction(l10n, entry, updates[entry.id]),
              ),
          ],
        );
      },
    );
  }

  Widget? _catalogAction(AppLocalizations l10n, CatalogEntry entry, PluginUpdate? update) {
    if (!entry.installable) return null;
    if (update != null) {
      return FilledButton.tonal(
        onPressed: _busy ? null : () => _run(() => _manager.prepareFromCatalog(entry)),
        child: Text(l10n.pluginsUpdateTo(entry.version)),
      );
    }
    if (_manager[entry.id] != null) return Text(l10n.pluginsUpToDate);
    return FilledButton.tonal(
      onPressed: _busy ? null : () => _run(() => _manager.prepareFromCatalog(entry)),
      child: Text(l10n.pluginsInstall),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

String _statusLabel(AppLocalizations l10n, PluginStatus status) => switch (status) {
  PluginStatus.running => l10n.pluginsStatusRunning,
  PluginStatus.disabled => l10n.pluginsStatusDisabled,
  PluginStatus.needsApproval => l10n.pluginsStatusNeedsApproval,
  PluginStatus.failed => l10n.pluginsStatusFailed,
};

String permissionLabel(AppLocalizations l10n, PluginPermission permission) => switch (permission) {
  NetworkPermission(:final hosts) => l10n.pluginsPermissionNetwork(hosts.join(", ")),
  StoragePermission() => l10n.pluginsPermissionStorage,
  PlaybackControlPermission() => l10n.pluginsPermissionPlaybackControl,
  NowPlayingPermission() => l10n.pluginsPermissionNowPlaying,
  LibraryReadPermission() => l10n.pluginsPermissionLibraryRead,
};

IconData _permissionIcon(PluginPermission permission) => switch (permission) {
  NetworkPermission() => TablerIcons.world,
  StoragePermission() => TablerIcons.database,
  PlaybackControlPermission() => TablerIcons.player_play,
  NowPlayingPermission() => TablerIcons.music,
  LibraryReadPermission() => TablerIcons.books,
};

String extensionLabel(AppLocalizations l10n, PluginExtension extension) => switch (extension.point) {
  ExtensionPoint.lyrics => l10n.pluginsPointLyrics,
  ExtensionPoint.coverArt => l10n.pluginsPointCoverArt,
  ExtensionPoint.metadata => l10n.pluginsPointMetadata,
  ExtensionPoint.radioDirectory => l10n.pluginsPointRadioDirectory,
  ExtensionPoint.scrobbler => l10n.pluginsPointScrobbler,
  ExtensionPoint.source => l10n.pluginsPointSource,
  ExtensionPoint.command => l10n.pluginsPointCommand(extension.title ?? extension.id ?? ""),
};

enum _ApprovalMode { install, update, enable }

/// Shows what a plugin will be allowed to do; true when the user approves.
Future<bool> _showPluginApproval(
  BuildContext context, {
  required PluginManifest manifest,
  required List<PluginPermission> permissions,
  required _ApprovalMode mode,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(switch (mode) {
        _ApprovalMode.install => l10n.pluginsApproveInstallTitle(manifest.name),
        _ApprovalMode.update => l10n.pluginsApproveUpdateTitle(manifest.name),
        _ApprovalMode.enable => l10n.pluginsApproveEnableTitle(manifest.name),
      }),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.pluginsVersionBy(manifest.version, manifest.author)),
            if (manifest.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(manifest.description, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            if (permissions.isEmpty)
              Text(l10n.pluginsApproveNothing)
            else ...[
              Text(mode == _ApprovalMode.update ? l10n.pluginsApproveAsksMore : l10n.pluginsApproveAsks),
              for (final permission in permissions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_permissionIcon(permission)),
                  title: Text(permissionLabel(l10n, permission)),
                ),
            ],
            const SizedBox(height: 8),
            Text(l10n.pluginsApproveSandbox, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.pluginsApprove)),
      ],
    ),
  );
  return result ?? false;
}

/// One plugin: what it provides, its permissions, its log, and uninstalling.
class PluginDetailsScreen extends StatelessWidget {
  const PluginDetailsScreen({super.key, required this.pluginId});

  final String pluginId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final manager = GetIt.instance<PluginManager>();
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final plugin = manager[pluginId];
        if (plugin == null) return Scaffold(appBar: AppBar());
        final manifest = plugin.manifest;
        final log = manager.logFor(pluginId);
        return Scaffold(
          appBar: AppBar(title: Text(manifest.name)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              ListTile(
                title: Text(l10n.pluginsVersionBy(manifest.version, manifest.author)),
                subtitle: Text(
                  [
                    if (manifest.description.isNotEmpty) manifest.description,
                    manifest.id,
                    plugin.record.origin.catalogUrl != null
                        ? l10n.pluginsFromCatalog(Uri.parse(plugin.record.origin.catalogUrl!).host)
                        : l10n.pluginsFromFile,
                  ].join("\n"),
                ),
              ),
              SwitchListTile(
                title: Text(_statusLabel(l10n, plugin.status)),
                subtitle: plugin.problem == null
                    ? null
                    : Text(plugin.problem!, style: TextStyle(color: theme.colorScheme.error)),
                value: plugin.record.enabled,
                onChanged: (value) async {
                  var approve = false;
                  if (value && plugin.unapproved.isNotEmpty) {
                    approve = await _showPluginApproval(
                      context,
                      manifest: manifest,
                      permissions: plugin.unapproved,
                      mode: _ApprovalMode.enable,
                    );
                    if (!approve) return;
                  }
                  await manager.setEnabled(pluginId, value, approve: approve);
                },
              ),
              _Header(l10n.pluginsProvides),
              for (final extension in manifest.extensions)
                ListTile(
                  dense: true,
                  leading: const Icon(TablerIcons.puzzle),
                  title: Text(extensionLabel(l10n, extension)),
                ),
              _Header(l10n.pluginsPermissions),
              if (manifest.permissions.isEmpty) ListTile(dense: true, title: Text(l10n.pluginsNoPermissions)),
              for (final permission in manifest.permissions)
                ListTile(
                  dense: true,
                  leading: Icon(_permissionIcon(permission)),
                  title: Text(permissionLabel(l10n, permission)),
                  trailing: plugin.unapproved.any((u) => u.type == permission.type)
                      ? Icon(TablerIcons.alert_triangle, color: theme.colorScheme.error)
                      : const Icon(TablerIcons.check),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (manifest.homepage != null)
                      OutlinedButton.icon(
                        onPressed: () => launchUrl(Uri.parse(manifest.homepage!), mode: LaunchMode.externalApplication),
                        icon: const Icon(TablerIcons.external_link),
                        label: Text(l10n.pluginsWebsite),
                      ),
                    if (manifest.has<StoragePermission>())
                      OutlinedButton.icon(
                        onPressed: () async {
                          await manager.clearData(pluginId);
                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(l10n.pluginsDataCleared)));
                          }
                        },
                        icon: const Icon(TablerIcons.eraser),
                        label: Text(l10n.pluginsClearData),
                      ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            content: Text(l10n.pluginsUninstallConfirm(manifest.name)),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: Text(l10n.pluginsUninstall),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        await manager.uninstall(pluginId);
                        if (context.mounted) Navigator.pop(context);
                      },
                      icon: const Icon(TablerIcons.trash),
                      label: Text(l10n.pluginsUninstall),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(child: _Header(l10n.pluginsLogs)),
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 12),
                    child: TextButton(onPressed: log.clear, child: Text(l10n.pluginsClearLogs)),
                  ),
                ],
              ),
              _PluginLogView(log: log),
            ],
          ),
        );
      },
    );
  }
}

class _PluginLogView extends StatelessWidget {
  const _PluginLogView({required this.log});

  final PluginLog log;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return StreamBuilder<void>(
      stream: log.changes,
      builder: (context, _) {
        final entries = log.entries.reversed.take(200).toList();
        if (entries.isEmpty) return ListTile(dense: true, title: Text(l10n.pluginsNoLogs));
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      "${TimeOfDay.fromDateTime(entry.time).format(context)}  ${entry.level.name.toUpperCase()}  "
                      "${entry.message}",
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: "monospace",
                        color: switch (entry.level) {
                          PluginLogLevel.error => theme.colorScheme.error,
                          PluginLogLevel.warning => theme.colorScheme.tertiary,
                          _ => null,
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
