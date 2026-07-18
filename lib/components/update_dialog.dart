import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/services/update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> checkForUpdatesInteractive(
  BuildContext context, {
  bool silentIfUpToDate = true,
  // Re-download and reinstall the latest release even if it isn't newer than
  // the installed build. Used by the long-press "reinstall" action.
  bool reinstall = false,
}) async {
  final info = await UpdateService().checkForUpdate(ignoreVersion: reinstall);
  if (!context.mounted) return;
  if (info == null) {
    if (!silentIfUpToDate) {
      GlobalSnackbar.message(
        (c) => reinstall ? "Couldn't reach GitHub releases." : "You're on the latest version.",
        isConfirmation: !reinstall,
      );
    }
    return;
  }
  await showDialog<void>(
    context: context,
    // A forced update can't be tapped away or dismissed with the scrim.
    barrierDismissible: !info.force,
    builder: (_) => UpdateDialog(info: info, reinstall: reinstall),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.info, this.reinstall = false});

  final UpdateInfo info;

  /// Whether this dialog is a forced re-download of the current version rather
  /// than an upgrade (affects wording only).
  final bool reinstall;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _installing = false;
  double? _progress;

  /// Android/Windows/macOS download and launch the installer in-app; Linux and
  /// asset-less releases fall back to opening the release page.
  bool get _canInstallInApp => UpdateService.canInstallInApp(widget.info.assetUrl);

  Future<void> _onPrimaryAction() async {
    if (_canInstallInApp) {
      await _downloadAndInstall();
    } else {
      await _openDownloadUrl();
    }
  }

  Future<void> _openDownloadUrl() async {
    final uri = Uri.parse(widget.info.downloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    // Keep a forced update on screen until the user actually installs it.
    if (mounted && !widget.info.force) Navigator.of(context).pop();
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _installing = true;
      _progress = null;
    });
    try {
      await UpdateService().downloadAndInstall(
        widget.info.assetUrl!,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      // The installer has been launched; close our dialog.
      if (mounted) Navigator.of(context).pop();
    } on UpdateException catch (e) {
      if (mounted) setState(() => _installing = false);
      GlobalSnackbar.message((c) => e.message);
    } catch (e) {
      if (mounted) setState(() => _installing = false);
      GlobalSnackbar.message((c) => "Update failed: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.info;
    return PopScope(
      // Block the Android back button / predictive-back for forced updates.
      canPop: !info.force,
      child: AlertDialog(
        icon: Icon(
          widget.reinstall
              ? TablerIcons.refresh
              : (info.force ? TablerIcons.alert_triangle : TablerIcons.arrow_up_circle),
        ),
        title: Text(widget.reinstall ? "Reinstall Diapason" : (info.force ? "Update required" : "Update available")),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.reinstall
                    ? "Download and reinstall version ${info.version} from GitHub."
                    : "Version ${info.version} is available — you have ${info.currentVersion}.",
                style: theme.textTheme.bodyMedium,
              ),
              if (info.force) ...[
                const SizedBox(height: 8),
                Text(
                  "This version is required to keep using Diapason.",
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text("What's new", style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                Flexible(
                  child: SingleChildScrollView(child: Text(info.notes, style: theme.textTheme.bodySmall)),
                ),
              ],
              if (_installing) ...[
                const SizedBox(height: 20),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 6),
                Text(
                  _progress == null ? "Downloading…" : "Downloading… ${(_progress! * 100).round()}%",
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!info.force)
            TextButton(onPressed: _installing ? null : () => Navigator.of(context).pop(), child: const Text("Later")),
          FilledButton.icon(
            onPressed: _installing ? null : _onPrimaryAction,
            icon: Icon(_canInstallInApp ? TablerIcons.download : TablerIcons.external_link, size: 18),
            label: Text(widget.reinstall ? "Reinstall" : (_canInstallInApp ? "Update" : "Download")),
          ),
        ],
      ),
    );
  }
}
