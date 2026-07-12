import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/library_shortcut.dart';
import 'package:diapason/services/shortcuts/shortcut_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class ShortcutsScreen extends StatefulWidget {
  const ShortcutsScreen({super.key});

  static const routeName = "/shortcuts";

  @override
  State<ShortcutsScreen> createState() => _ShortcutsScreenState();
}

class _ShortcutsScreenState extends State<ShortcutsScreen> {
  ShortcutService get _shortcuts => GetIt.instance<ShortcutService>();

  @override
  Widget build(BuildContext context) {
    final pins = _shortcuts.pins;
    final searches = _shortcuts.recentSearches;

    return Scaffold(
      appBar: AppBar(title: const Text("Pins & searches")),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              "Pinned (${pins.length}/${ShortcutService.maxPins})",
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (pins.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text("Pin an album, artist or playlist to keep it here and on your home screen."),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: true,
              onReorder: (oldIndex, newIndex) async {
                final reordered = List.of(pins);
                if (newIndex > oldIndex) newIndex -= 1;
                reordered.insert(newIndex, reordered.removeAt(oldIndex));
                await _shortcuts.reorderPins(reordered);
                setState(() {});
              },
              children: [
                for (final pin in pins)
                  ListTile(
                    key: ValueKey(pin.itemId),
                    leading: Icon(_iconFor(pin.type)),
                    title: Text(pin.name),
                    subtitle: pin.subtitle == null ? null : Text(pin.subtitle!),
                    trailing: IconButton(
                      icon: const Icon(TablerIcons.pinned_off),
                      onPressed: () async {
                        await _shortcuts.unpin(BaseItemId(pin.itemId));
                        setState(() {});
                      },
                    ),
                  ),
              ],
            ),

          const Divider(height: 32),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Recent searches", style: Theme.of(context).textTheme.titleMedium),
                if (searches.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      await _shortcuts.clearSearchHistory();
                      setState(() {});
                    },
                    child: const Text("Clear"),
                  ),
              ],
            ),
          ),
          if (searches.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text("Nothing searched yet."),
            )
          else
            for (final entry in searches)
              ListTile(
                leading: const Icon(TablerIcons.history),
                title: Text(entry.query),
                trailing: IconButton(
                  icon: const Icon(TablerIcons.x),
                  onPressed: () async {
                    await _shortcuts.removeSearch(entry.query);
                    setState(() {});
                  },
                ),
              ),
        ],
      ),
    );
  }

  static IconData _iconFor(String type) => switch (type) {
    "MusicArtist" => TablerIcons.microphone_2,
    "Playlist" => TablerIcons.playlist,
    _ => TablerIcons.disc,
  };
}
