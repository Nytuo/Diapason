import 'package:diapason/components/SmartPlaylist/smart_playlist_editor.dart';
import 'package:diapason/components/SmartPlaylist/smart_playlist_tracks.dart';
import 'package:diapason/components/now_playing_bar.dart';
import 'package:diapason/models/smart_playlist.dart';
import 'package:diapason/services/smart_playlist_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class SmartPlaylistsScreen extends StatefulWidget {
  const SmartPlaylistsScreen({super.key});

  static const routeName = "/smart-playlists";

  @override
  State<SmartPlaylistsScreen> createState() => _SmartPlaylistsScreenState();
}

class _SmartPlaylistsScreenState extends State<SmartPlaylistsScreen> {
  List<SmartPlaylist> _playlists = [];
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
    });
  }

  Future<void> _create() async {
    final created = await showSmartPlaylistEditor(context);
    if (created == null) return;
    await SmartPlaylistService.instance.save(created);
    await _load();
  }

  Future<void> _delete(SmartPlaylist p) async {
    await SmartPlaylistService.instance.delete(p.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Smart Playlists")),
      bottomNavigationBar: const NowPlayingBar(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(TablerIcons.plus),
        label: const Text("New"),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _playlists.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(TablerIcons.bolt, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  const Text("No smart playlists yet"),
                  const SizedBox(height: 4),
                  Text(
                    "Create one to auto-collect tracks by rules",
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _playlists.length,
              itemBuilder: (context, index) {
                final p = _playlists[index];
                return ListTile(
                  leading: const Icon(TablerIcons.bolt),
                  title: Text(p.name),
                  subtitle: Text("${p.rules.length} rule${p.rules.length == 1 ? '' : 's'} · match ${p.matchAll ? 'all' : 'any'}"),
                  trailing: IconButton(
                    icon: const Icon(TablerIcons.trash),
                    onPressed: () => _delete(p),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text(p.name)),
                        bottomNavigationBar: const NowPlayingBar(),
                        body: SmartPlaylistTracks(playlist: p, onChanged: _load),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
