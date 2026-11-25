import 'package:diapason/components/TagEditor/tag_editor_page.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// "Edit tags" for tracks and albums. Shown for every source with tags
/// (read-only ones explain why inside the editor); hidden for YouTube.
class EditTagsMenuEntry extends StatelessWidget implements HideableMenuEntry {
  const EditTagsMenuEntry({super.key, required this.baseItem});

  final BaseItemDto baseItem;

  @override
  bool get isVisible {
    if (baseItem.type != "Audio" && baseItem.type != "MusicAlbum") return false;
    if (!GetIt.instance.isRegistered<BackendRegistry>()) return false;
    final kind = GetIt.instance<BackendRegistry>().forItem(baseItem)?.config.kind;
    return kind != null && kind != MediaSourceKind.youtube;
  }

  @override
  Widget build(BuildContext context) {
    return Visibility(
      visible: isVisible,
      child: MenuEntry(
        icon: TablerIcons.tags,
        title: AppLocalizations.of(context)!.tagEditorMenuEntry,
        onTap: () {
          final navigator = Navigator.of(context, rootNavigator: true);
          Navigator.pop(context); // close menu
          showTagEditor(navigator, baseItem);
        },
      ),
    );
  }
}
