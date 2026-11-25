import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/plugins/extension_points.dart';
import 'package:diapason/services/plugins/plugin_runtime.dart';
import 'package:diapason/services/plugins/plugins.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = Logger("PluginCommand");

/// The menu actions enabled plugins contribute for [item]; empty when there are none.
List<HideableMenuEntry> pluginCommandMenuEntries(BaseItemDto item) {
  if (!GetIt.instance.isRegistered<ExtensionRegistry>()) return const [];
  final commandItem = commandItemFor(item);
  if (commandItem == null) return const [];
  return [
    for (final command in GetIt.instance<ExtensionRegistry>().commandsFor(commandItem.target))
      PluginCommandMenuEntry(command: command, item: commandItem),
  ];
}

class PluginCommandMenuEntry extends StatelessWidget implements HideableMenuEntry {
  const PluginCommandMenuEntry({super.key, required this.command, required this.item});

  final ItemCommandExtension command;
  final CommandItem item;

  @override
  Widget build(BuildContext context) {
    return MenuEntry(
      icon: TablerIcons.plug,
      title: command.title,
      onTap: () async {
        Navigator.pop(context);
        final l10n = GlobalSnackbar.requireL10n;
        try {
          final result = await command.run(item);
          if (result.openUrl != null) {
            await launchUrl(result.openUrl!, mode: LaunchMode.externalApplication);
          }
          if (result.message != null || result.openUrl == null) {
            GlobalSnackbar.message((_) => result.message ?? l10n.pluginsCommandDone);
          }
        } catch (e, s) {
          final reason = e is PluginCallException ? e.message : FriendlyError.report(_log, command.title, e, s);
          GlobalSnackbar.message((_) => l10n.pluginsCommandFailed(command.title, reason));
        }
      },
    );
  }

  @override
  bool get isVisible => true;
}
