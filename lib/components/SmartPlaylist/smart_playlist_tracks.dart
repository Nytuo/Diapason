import 'package:diapason/components/AlbumScreen/track_list_tile.dart';
import 'package:diapason/components/SmartPlaylist/smart_playlist_editor.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/music_models.dart';
import 'package:diapason/models/smart_playlist.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/smart_playlist_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class SmartPlaylistTracks extends StatefulWidget {
  const SmartPlaylistTracks({super.key, required this.playlist, this.onChanged});

  final SmartPlaylist playlist;

  final VoidCallback? onChanged;

  @override
  State<SmartPlaylistTracks> createState() => _SmartPlaylistTracksState();
}

class _SmartPlaylistTracksState extends State<SmartPlaylistTracks> {
  late SmartPlaylist _playlist;
  late Future<List<BaseItemDto>> _future;

  @override
  void initState() {
    super.initState();
    _playlist = widget.playlist;
    _reload();
  }

  @override
  void didUpdateWidget(SmartPlaylistTracks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.id != widget.playlist.id) {
      _playlist = widget.playlist;
      _reload();
    }
  }

  void _reload() {
    _future = SmartPlaylistService.instance.resolve(_playlist);
  }

  QueueItemSource _source() => QueueItemSource.rawId(
    type: QueueItemSourceType.allTracks,
    name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: _playlist.name),
    id: _playlist.id,
  );

  Future<void> _play(List<BaseItemDto> tracks, {required bool shuffle}) async {
    if (tracks.isEmpty) return;
    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: _source(),
      order: shuffle ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear,
    );
  }

  Future<void> _edit() async {
    final updated = await showSmartPlaylistEditor(context, existing: _playlist);
    if (updated == null) return;
    await SmartPlaylistService.instance.save(updated);
    if (!mounted) return;
    setState(() {
      _playlist = updated;
      _reload();
    });
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<BaseItemDto>>(
      future: _future,
      builder: (context, snapshot) {
        final tracks = snapshot.data ?? [];
        final loading = snapshot.connectionState == ConnectionState.waiting;
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Icon(TablerIcons.bolt, color: theme.colorScheme.primary, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_playlist.name, style: theme.textTheme.headlineSmall),
                          Text(
                            loading ? "Resolving…" : "${tracks.length} tracks",
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () => _play(tracks, shuffle: false),
                      icon: const Icon(TablerIcons.player_play_filled, size: 18),
                      label: const Text("Play"),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: "Shuffle",
                      onPressed: () => _play(tracks, shuffle: true),
                      icon: const Icon(TablerIcons.arrows_shuffle),
                    ),
                    IconButton(tooltip: "Edit rules", onPressed: _edit, icon: const Icon(TablerIcons.edit)),
                  ],
                ),
              ),
            ),
            if (loading)
              const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
            else if (tracks.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Text("No tracks match these rules", style: theme.textTheme.bodyLarge),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  return TrackListTile(
                    key: ValueKey(tracks[index].id),
                    item: tracks[index],
                    index: index,
                    showIndex: false,
                    parentPlayable: PrecalculatedPlayable(source: _source(), tracks: tracks),
                  );
                }, childCount: tracks.length),
              ),
          ],
        );
      },
    );
  }
}
