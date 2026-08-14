import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/hidden_items_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class HideFromBrowseMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  final BaseItemDto baseItem;

  const HideFromBrowseMenuEntry({super.key, required this.baseItem});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hiddenIds = ref.watch(hiddenItemIdsProvider).valueOrNull ?? HiddenItemsService.hiddenIds;
    final isHidden = hiddenIds.contains(baseItem.id.raw);

    return MenuEntry(
      icon: isHidden ? TablerIcons.eye : TablerIcons.eye_closed,
      title: isHidden
          ? AppLocalizations.of(context)!.unhideFromBrowse
          : AppLocalizations.of(context)!.hideFromBrowse,
      onTap: () async {
        if (isHidden) {
          await HiddenItemsService.unhide(baseItem.id);
        } else {
          await HiddenItemsService.hide(baseItem.id);
        }
        if (context.mounted) Navigator.pop(context);
      },
    );
  }

  @override
  bool get isVisible => true;
}
