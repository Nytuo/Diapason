import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/screens/logs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class ViewLogsMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const ViewLogsMenuEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Visibility(
      visible: true,
      child: MenuEntry(
        enabled: true,
        icon: TablerIcons.logs,
        title: AppLocalizations.of(context)!.snackbarOptionsMenuViewLogsButton,
        onTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).pushNamed(LogsScreen.routeName);
        },
      ),
    );
  }

  @override
  bool get isVisible => true;
}
