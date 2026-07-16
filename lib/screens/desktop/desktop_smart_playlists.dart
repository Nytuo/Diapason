import 'package:diapason/components/SmartPlaylist/smart_playlist_editor.dart';
import 'package:diapason/components/SmartPlaylist/smart_playlist_tracks.dart';
import 'package:diapason/models/smart_playlist.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/smart_playlist_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class DesktopSmartPlaylists extends StatefulWidget {
  const DesktopSmartPlaylists({super.key});

  @override
  State<DesktopSmartPlaylists> createState() => _DesktopSmartPlaylistsState();
}

class _DesktopSmartPlaylistsState extends State<DesktopSmartPlaylists> {
  List<SmartPlaylist> _playlists = [];
  SmartPlaylist? _selected;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await SmartPlaylistService.instance.list();
    if (!mounted) return;
    setState(() {
      _playlists = list;
      _loading = false;
      if (_selected != null) {
        _selected = list.where((p) => p.id == _selected!.id).firstOrNull;
      }
      _selected ??= list.firstOrNull;
    });
  }

  Future<void> _create() async {
    final created = await showSmartPlaylistEditor(context);
    if (created == null) return;
    await SmartPlaylistService.instance.save(created);
    _selected = created;
    await _load();
  }

  Future<void> _delete(SmartPlaylist p) async {
    await SmartPlaylistService.instance.delete(p.id);
    if (_selected?.id == p.id) _selected = null;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return Material(
      color: p.bg,
      child: Row(
        children: [
          Container(
            width: 260,
            decoration: BoxDecoration(border: Border(right: BorderSide(color: p.borderSubtle))),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(TablerIcons.plus, size: 18),
                    label: const Text("New Smart Playlist"),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          itemCount: _playlists.length,
                          itemBuilder: (context, index) {
                            final item = _playlists[index];
                            final active = _selected?.id == item.id;
                            return ListTile(
                              selected: active,
                              selectedTileColor: p.accentMuted,
                              leading: Icon(TablerIcons.bolt, size: 20, color: active ? p.accent : p.textSecondary),
                              title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: IconButton(
                                iconSize: 18,
                                icon: const Icon(TablerIcons.trash),
                                onPressed: () => _delete(item),
                              ),
                              onTap: () => setState(() => _selected = item),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _selected == null
                ? Center(
                    child: Text(
                      _loading ? "" : "Create a smart playlist to get started",
                      style: TextStyle(color: p.textTertiary),
                    ),
                  )
                : SmartPlaylistTracks(
                    key: ValueKey(_selected!.id),
                    playlist: _selected!,
                    onChanged: _load,
                  ),
          ),
        ],
      ),
    );
  }
}
