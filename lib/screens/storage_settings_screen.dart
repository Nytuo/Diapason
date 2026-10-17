import 'dart:io';

import 'package:diapason/screens/cache_settings_screen.dart';
import 'package:diapason/screens/downloads_settings_screen.dart';
import 'package:diapason/screens/logs_screen.dart';
import 'package:diapason/screens/ytdlp_settings_screen.dart';
import 'package:diapason/services/album_image_provider.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/log_level.dart';
import 'package:diapason/services/stream_cache_service.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:file_sizes/file_sizes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class StorageSettingsScreen extends ConsumerStatefulWidget {
  const StorageSettingsScreen({
    super.key,
    this.coverArtBytes = albumImageCacheBytes,
    this.clearCoverArt = clearAlbumImageCache,
  });

  final Future<int> Function() coverArtBytes;
  final Future<void> Function() clearCoverArt;

  static const routeName = "/settings/storage";

  @override
  ConsumerState<StorageSettingsScreen> createState() => _StorageSettingsScreenState();
}

class _StorageSettingsScreenState extends ConsumerState<StorageSettingsScreen> {
  static final _log = Logger("StorageSettingsScreen");

  int _generation = 0;

  Future<int> _dirBytes(Directory dir) async {
    if (!dir.existsSync()) return 0;
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) total += await e.length();
      }
    } catch (e) {
      _log.fine("Couldn't measure ${dir.path}: $e");
    }
    return total;
  }

  Future<File> _logFile(String name) async {
    final base = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();
    return File(p.join(base.path, name));
  }

  Future<int> _logBytes() async {
    var total = 0;
    for (final name in const ["diapason-logs.txt", "diapason-logs-old.txt"]) {
      final f = await _logFile(name);
      if (f.existsSync()) total += await f.length();
    }
    return total;
  }

  Future<void> _clear(String what, Future<void> Function() action) async {
    try {
      await action();
      _log.info("Cleared $what");
      if (mounted) {
        setState(() => _generation++);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$what cleared")));
      }
    } catch (e, stack) {
      final why = FriendlyError.report(_log, "Clearing $what", e, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't clear $what. $why")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = LogDetail.fromId(ref.watch(finampSettingsProvider.logLevel));

    return Scaffold(
      appBar: AppBar(title: const Text("Storage & diagnostics")),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          _header(theme, "What the app keeps on this device"),
          _SizeTile(
            key: ValueKey("stream$_generation"),
            icon: TablerIcons.music,
            title: "Streamed tracks",
            subtitle: "Copies kept while you listen, so replays don't download again.",
            measure: () => GetIt.instance<StreamCacheService>().currentSizeBytes(),
            onClear: () => _clear("Streamed track cache", () => GetIt.instance<StreamCacheService>().clear()),
            onOpen: () => Navigator.of(context).pushNamed(CacheSettingsScreen.routeName),
          ),
          _SizeTile(
            key: ValueKey("art$_generation"),
            icon: TablerIcons.photo,
            title: "Cover art",
            subtitle: "Album and artist pictures. They're fetched again when needed.",
            measure: widget.coverArtBytes,
            onClear: () => _clear("Cover art cache", widget.clearCoverArt),
          ),
          _SizeTile(
            key: ValueKey("logs$_generation"),
            icon: TablerIcons.file_text,
            title: "Log files",
            subtitle: "Used for bug reports. Only the older log can be deleted; the current one is in use.",
            measure: _logBytes,
            clearLabel: "Delete old",
            onClear: () => _clear("Old log", () async {
              final old = await _logFile("diapason-logs-old.txt");
              if (old.existsSync()) await old.delete();
            }),
            onOpen: () => Navigator.of(context).pushNamed(LogsScreen.routeName),
          ),
          if (LocalYtDlpService.supported)
            _SizeTile(
              key: ValueKey("ytdlp$_generation"),
              icon: TablerIcons.brand_youtube,
              title: "yt-dlp and Deno",
              subtitle: "The copies Diapason downloaded for YouTube on this computer.",
              measure: () async => _dirBytes(await YtDlpPaths.managedDir()),
              onOpen: () => Navigator.of(context).pushNamed(YtDlpSettingsScreen.routeName),
            ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text("Downloaded music"),
            subtitle: const Text("Manage locations and what's kept offline"),
            trailing: const Icon(TablerIcons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed(DownloadsSettingsScreen.routeName),
          ),
          const Divider(height: 32),
          _header(theme, "Log detail"),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<LogDetail>(
              showSelectedIcon: false,
              segments: [for (final d in LogDetail.values) ButtonSegment(value: d, label: Text(d.label))],
              selected: {detail},
              onSelectionChanged: (selection) {
                FinampSetters.setLogLevel(selection.first.id);
                applyConfiguredLogLevel();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(detail.description, style: theme.textTheme.bodySmall),
          ),
          ListTile(
            leading: const Icon(TablerIcons.bug),
            title: const Text("View and share logs"),
            trailing: const Icon(TablerIcons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed(LogsScreen.routeName),
          ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
  );
}

class _SizeTile extends StatefulWidget {
  const _SizeTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.measure,
    this.onClear,
    this.onOpen,
    this.clearLabel = "Clear",
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Future<int> Function() measure;
  final Future<void> Function()? onClear;
  final VoidCallback? onOpen;
  final String clearLabel;

  @override
  State<_SizeTile> createState() => _SizeTileState();
}

class _SizeTileState extends State<_SizeTile> {
  late final Future<int> _size = widget.measure();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(widget.icon),
      title: Text(widget.title),
      subtitle: Text(widget.subtitle),
      onTap: widget.onOpen,
      trailing: FutureBuilder<int>(
        future: _size,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                snapshot.connectionState != ConnectionState.done
                    ? "…"
                    : bytes == null
                    ? "?"
                    : FileSize.getSize(bytes),
              ),
              if (widget.onClear != null) ...[
                const SizedBox(width: 8),
                TextButton(onPressed: (bytes ?? 0) == 0 ? null : widget.onClear, child: Text(widget.clearLabel)),
              ],
            ],
          );
        },
      ),
    );
  }
}
