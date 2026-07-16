import 'package:diapason/components/update_dialog.dart';
import 'package:diapason/screens/connect_screen.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/downloads_screen.dart';
import 'package:diapason/screens/import_screen.dart';
import 'package:diapason/screens/logs_screen.dart';
import 'package:diapason/screens/playback_history_screen.dart';
import 'package:diapason/screens/uploader_settings_screen.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class DesktopAppMenu extends ConsumerWidget {
  const DesktopAppMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = DesktopThemeScope.of(context);
    final rpcEnabled = ref.watch(finampSettingsProvider.rpcEnabled);

    void push(String route) => Navigator.of(context).pushNamed(route);

    return PopupMenuButton<VoidCallback>(
      tooltip: "Menu",
      iconSize: 18,
      color: p.surface,
      icon: Icon(TablerIcons.dots, color: p.textTertiary),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        _item(p, TablerIcons.download, "Downloads", () => push(DownloadsScreen.routeName)),
        _item(p, TablerIcons.wifi, "Diapason Connect", () => push(ConnectScreen.routeName)),
        _item(p, TablerIcons.device_mobile, "Send to / import from mobile", () => push(ImportScreen.routeName)),
        _item(p, TablerIcons.upload, "Uploader", () => push(UploaderSettingsScreen.routeName)),
        const PopupMenuDivider(),
        _item(p, TablerIcons.history, "Playback history", () => push(PlaybackHistoryScreen.routeName)),
        _item(p, TablerIcons.file_text, "Logs", () => push(LogsScreen.routeName)),
        CheckedPopupMenuItem<VoidCallback>(
          checked: rpcEnabled,
          value: () => FinampSetters.setRpcEnabled(!rpcEnabled),
          child: const Text("Discord Rich Presence"),
        ),
        const PopupMenuDivider(),
        _item(
          p,
          TablerIcons.arrow_up_circle,
          "Check for updates",
          () => checkForUpdatesInteractive(context, silentIfUpToDate: false),
        ),
      ],
    );
  }

  PopupMenuItem<VoidCallback> _item(DesktopPalette p, IconData icon, String label, VoidCallback onTap) {
    return PopupMenuItem<VoidCallback>(
      value: onTap,
      child: Row(
        children: [
          Icon(icon, size: 18, color: p.textSecondary),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

}
