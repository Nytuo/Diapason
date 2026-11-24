import 'package:diapason/l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final bytes = await _service.export(includeSignIns: _includeSignIns);
      if (_isDesktop) {
        final saved = await FilePicker.saveFile(
          dialogTitle: l10n.backupDialogTitle,
          fileName: BackupService.suggestedFileName(),
          mimeType: "application/json",
          bytes: bytes,
        );
        if (saved == null) return;
        _toast(l10n.backupSaved);
      } else {
        // On phones the share sheet covers Files, Drive, AirDrop, email, …
        final file = await writeBackupToTemp(bytes);
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: "application/json")],
            subject: l10n.backupSubject,
            sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      }
    } catch (e) {
      _toast(l10n.backupFailed("$e"));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final l10n = AppLocalizations.of(context)!;
    final file = await FilePicker.pickFile(dialogTitle: l10n.backupPickTitle);
    if (file == null) return;

    Uint8List? bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      bytes = null;
    }
    if (bytes == null) {
      _toast(l10n.backupUnreadable);
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
        title: Text(AppLocalizations.of(context)!.backupRestoreTitle),
        content: Text(
          [
            if (created != null)
              AppLocalizations.of(context)!.backupMadeOn(MaterialLocalizations.of(context).formatMediumDate(created)),
            AppLocalizations.of(context)!.backupRestoreBody,
            if (info["includesSignIns"] != true) AppLocalizations.of(context)!.backupNoSignIns,
          ].join("\n\n"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.backupCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.backupRestore),
          ),
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
          title: Text(AppLocalizations.of(context)!.backupRestored),
          content: Text(
            [
              if (report.summary().isNotEmpty) AppLocalizations.of(context)!.backupRestoredSummary(report.summary()),
              if (report.jellyfinSignedIn) AppLocalizations.of(context)!.backupSignedBackIn,
              if (report.sourcesNeedingSignIn > 0)
                AppLocalizations.of(context)!.backupSourcesNeedSignIn(report.sourcesNeedingSignIn),
              if (report.sourcesSkipped > 0) AppLocalizations.of(context)!.backupSourcesSkipped(report.sourcesSkipped),
              AppLocalizations.of(context)!.backupRestart,
            ].join("\n\n"),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text("OK"))],
        ),
      );
    } on BackupFormatException catch (e) {
      _toast(e.message);
    } catch (e) {
      if (mounted) _toast(AppLocalizations.of(context)!.backupRestoreFailed("$e"));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.backupTitle)),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          children: [
            if (_busy) const LinearProgressIndicator(),
            Text(AppLocalizations.of(context)!.backupIntro, style: textTheme.bodyMedium),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _includeSignIns,
                    onChanged: (value) => setState(() => _includeSignIns = value),
                    title: Text(AppLocalizations.of(context)!.backupIncludeSignIns),
                    subtitle: Text(
                      _includeSignIns
                          ? AppLocalizations.of(context)!.backupSignInsOn
                          : AppLocalizations.of(context)!.backupSignInsOff,
                    ),
                    secondary: Icon(_includeSignIns ? TablerIcons.key : TablerIcons.key_off),
                  ),
                  ListTile(
                    leading: const Icon(TablerIcons.download),
                    title: Text(
                      _isDesktop ? AppLocalizations.of(context)!.backupSave : AppLocalizations.of(context)!.backupShare,
                    ),
                    onTap: _busy ? null : _export,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(TablerIcons.upload),
                title: Text(AppLocalizations.of(context)!.backupRestoreFrom),
                subtitle: Text(AppLocalizations.of(context)!.backupPickFile),
                onTap: _busy ? null : _restore,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
