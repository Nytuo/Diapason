import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/backup/backup_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:share_plus/share_plus.dart';

/// Back up settings, sources, home layout, pins, smart playlists and lyrics timings to one file, and restore them.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  static const routeName = "/settings/backup";

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _service = BackupService();

  bool _includeSignIns = true;
  bool _busy = false;

  static bool get _isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final bytes = await _service.export(includeSignIns: _includeSignIns);
      if (_isDesktop) {
        final path = await FilePicker.saveFile(
          dialogTitle: "Save Diapason backup",
          fileName: BackupService.suggestedFileName(),
          type: FileType.custom,
          allowedExtensions: const ["json"],
        );
        if (path == null) return;
        await File(path).writeAsBytes(bytes, flush: true);
        _toast("Backup saved.");
      } else {
        // On phones the share sheet covers Files, Drive, AirDrop, email, …
        final file = await writeBackupToTemp(bytes);
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: "application/json")],
            subject: "Diapason backup",
            sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      }
    } catch (e) {
      _toast("Couldn't make the backup: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final picked = await FilePicker.pickFiles(dialogTitle: "Choose a Diapason backup", withData: true);
    final file = picked?.files.singleOrNull;
    if (file == null) return;

    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) bytes = await File(file.path!).readAsBytes();
    if (bytes == null) {
      _toast("Couldn't read that file.");
      return;
    }

    final Map<String, dynamic> info;
    try {
      info = BackupService.parse(bytes);
    } on BackupFormatException catch (e) {
      _toast(e.message);
      return;
    }

    if (!mounted) return;
    final created = DateTime.tryParse(info["createdAt"] as String? ?? "")?.toLocal();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Restore this backup?"),
        content: Text(
          [
            if (created != null) "Made on ${MaterialLocalizations.of(context).formatMediumDate(created)}.",
            "Your settings and home layout are replaced; sources, pins and smart playlists are added to what you "
                "have. Download folders stay as they are on this device.",
            if (info["includesSignIns"] != true) "This backup has no sign-ins: you'll need to sign in to its sources.",
          ].join("\n\n"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text("Restore")),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final report = await _service.restore(bytes);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Backup restored"),
          content: Text(
            [
              if (report.summary().isNotEmpty) "Restored ${report.summary()}.",
              if (report.jellyfinSignedIn) "Signed back in to Jellyfin.",
              if (report.sourcesNeedingSignIn > 0)
                "${report.sourcesNeedingSignIn} source${report.sourcesNeedingSignIn == 1 ? " needs" : "s need"} "
                    "you to sign in again (Settings › Sources).",
              if (report.sourcesSkipped > 0)
                "${report.sourcesSkipped} source${report.sourcesSkipped == 1 ? " was" : "s were"} skipped: already "
                    "here, or a folder on the other device.",
              "Restart Diapason so everything picks the changes up.",
            ].join("\n\n"),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text("OK"))],
        ),
      );
    } on BackupFormatException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast("Couldn't restore that backup: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text("Backup & restore")),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          children: [
            if (_busy) const LinearProgressIndicator(),
            Text(
              "One file with your settings, home layout, sources, pins, smart playlists, hidden items and lyrics "
              "timings. Use it on a new device or after reinstalling.",
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _includeSignIns,
                    onChanged: (value) => setState(() => _includeSignIns = value),
                    title: const Text("Include sign-ins"),
                    subtitle: Text(
                      _includeSignIns
                          ? "Server and scrobbling sign-ins are in the file. Anyone with it can use your accounts: "
                                "keep it somewhere private."
                          : "No passwords or tokens in the file. You'll sign in again after restoring.",
                    ),
                    secondary: Icon(_includeSignIns ? TablerIcons.key : TablerIcons.key_off),
                  ),
                  ListTile(
                    leading: const Icon(TablerIcons.download),
                    title: Text(_isDesktop ? "Save a backup…" : "Back up and share…"),
                    onTap: _busy ? null : _export,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(TablerIcons.upload),
                title: const Text("Restore from a backup…"),
                subtitle: const Text("Pick a diapason-backup file"),
                onTap: _busy ? null : _restore,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
