import 'dart:io';

import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/menus/components/menuEntries/menu_entry.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/share_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:share_plus/share_plus.dart';

/// "Share link": a diapason:// link that opens this item in Diapason on another device.
class ShareLinkMenuEntry extends StatelessWidget implements HideableMenuEntry {
  const ShareLinkMenuEntry({super.key, required this.baseItem});

  final BaseItemDto baseItem;

  /// Windows and Linux have no share sheet worth using; the clipboard is what people expect there.
  static bool get _copyInstead => Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    return MenuEntry(
      icon: TablerIcons.share,
      title: _copyInstead ? "Copy link" : "Share link",
      onTap: () async {
        final text = ShareLinks.shareText(baseItem);
        if (_copyInstead) {
          await Clipboard.setData(ClipboardData(text: ShareLinks.linkFor(baseItem).toString()));
          if (context.mounted) Navigator.pop(context);
          GlobalSnackbar.message((_) => "Link copied");
          return;
        }
        final box = context.findRenderObject() as RenderBox?;
        final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
        await SharePlus.instance.share(ShareParams(text: text, sharePositionOrigin: origin));
        if (context.mounted) Navigator.pop(context);
      },
    );
  }

  @override
  bool get isVisible => true;
}
