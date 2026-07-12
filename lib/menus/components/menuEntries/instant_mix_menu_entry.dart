import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/audio_service_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Start Jellyfin Instant Mix for any item type
class InstantMixMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  final BaseItemDto baseItem;

  const InstantMixMenuEntry({super.key, required this.baseItem});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioServiceHelper = GetIt.instance<AudioServiceHelper>();

    return MenuEntry(
      icon: TablerIcons.compass,
      title: AppLocalizations.of(context)!.instantMix,
      onTap: () async {
        Navigator.pop(context); // close menu
        await audioServiceHelper.startInstantMixForItem(baseItem);

        GlobalSnackbar.message((context) => AppLocalizations.of(context)!.startingInstantMix, isConfirmation: true);
      },
    );
  }

  @override
  bool get isVisible => true;
}
