import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/services/update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> checkForUpdatesInteractive(BuildContext context, {bool silentIfUpToDate = true}) async {
  final info = await UpdateService().checkForUpdate();
  if (!context.mounted) return;
  if (info == null) {
    if (!silentIfUpToDate) {
      GlobalSnackbar.message((c) => "You're on the latest version.", isConfirmation: true);
    }
    return;
  }
  await showDialog<void>(context: context, builder: (_) => UpdateDialog(info: info));
}

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.info});

  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(TablerIcons.arrow_up_circle),
      title: const Text("Update available"),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Version ${info.version} is available — you have ${info.currentVersion}.",
              style: theme.textTheme.bodyMedium,
            ),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text("What's new", style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(info.notes, style: theme.textTheme.bodySmall),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Later"),
        ),
        FilledButton.icon(
          onPressed: () async {
            final uri = Uri.parse(info.downloadUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
            if (context.mounted) Navigator.of(context).pop();
          },
          icon: const Icon(TablerIcons.download, size: 18),
          label: const Text("Download"),
        ),
      ],
    );
  }
}
