import 'package:diapason/components/MusicScreen/similar_artists_section.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/scrobbling_settings_screen.dart';
import 'package:diapason/services/discovery/discovery_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class DiscoverTabView extends ConsumerStatefulWidget {
  const DiscoverTabView({super.key});

  @override
  ConsumerState<DiscoverTabView> createState() => _DiscoverTabViewState();
}

class _DiscoverTabViewState extends ConsumerState<DiscoverTabView> {
  DiscoveryService get _discovery => GetIt.instance<DiscoveryService>();

  late Future<List<FreshRelease>> _fresh = _discovery.freshReleases();
  Future<List<({String mbid, String title})>>? _playlists;

  String? _importing;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  void _loadPlaylists() {
    final username = FinampSettingsHelper.finampSettings.lastFmUsername;
    if (FinampSettingsHelper.finampSettings.listenBrainzToken.isEmpty || username.isEmpty) return;
    setState(() => _playlists = _discovery.listenBrainzPlaylists(username));
  }

  Future<void> _playPlaylist(({String mbid, String title}) playlist) async {
    setState(() => _importing = playlist.mbid);
    try {
      final recommended = await _discovery.listenBrainzPlaylistTracks(playlist.mbid);
      final tracks = await _discovery.resolve(recommended);

      if (!mounted) return;
      if (tracks.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Couldn't find any of those tracks.")));
        return;
      }

      await GetIt.instance<QueueService>().startPlayback(
        items: tracks,
        source: QueueItemSource(
          type: QueueItemSourceType.unknown,
          name: QueueItemSourceName(
            type: QueueItemSourceNameType.preTranslated,
            pretranslatedName: playlist.title,
          ),
          id: BaseItemId(playlist.mbid),
        ),
      );

      if (mounted) {
        final matched = tracks.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Playing $matched of ${recommended.length} tracks")),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(finampSettingsProvider.listenBrainzToken).isNotEmpty;

    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _fresh = _discovery.freshReleases());
        _loadPlaylists();
      },
      child: ListView(
        padding: const EdgeInsets.only(bottom: 120.0),
        children: [
          if (!connected)
            Card(
              margin: const EdgeInsets.all(12.0),
              child: ListTile(
                leading: const Icon(TablerIcons.plug_connected),
                title: const Text("Connect ListenBrainz"),
                subtitle: const Text("For playlists made from what you actually listen to"),
                trailing: const Icon(TablerIcons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(ScrobblingSettingsScreen.routeName),
              ),
            ),

          if (_playlists != null) ...[
            const _SectionHeader("Your playlists"),
            FutureBuilder<List<({String mbid, String title})>>(
              future: _playlists,
              builder: (context, snapshot) {
                final playlists = snapshot.data;
                if (playlists == null) {
                  return const Padding(padding: EdgeInsets.all(16.0), child: LinearProgressIndicator());
                }
                if (playlists.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text("No ListenBrainz playlists yet."),
                  );
                }
                return Column(
                  children: [
                    for (final playlist in playlists)
                      ListTile(
                        leading: const Icon(TablerIcons.playlist),
                        title: Text(playlist.title),
                        subtitle: const Text("Matched against your library, YouTube for the rest"),
                        trailing: _importing == playlist.mbid
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(TablerIcons.player_play),
                        onTap: _importing == null ? () => _playPlaylist(playlist) : null,
                      ),
                  ],
                );
              },
            ),
          ],

          const SimilarToNowPlaying(),

          const _SectionHeader("Fresh releases"),
          FutureBuilder<List<FreshRelease>>(
            future: _fresh,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(padding: EdgeInsets.all(16.0), child: LinearProgressIndicator());
              }
              final releases = snapshot.data ?? const [];
              if (releases.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text("Couldn't reach ListenBrainz."),
                );
              }
              return SizedBox(
                height: 210.0,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  itemCount: releases.length,
                  itemBuilder: (context, index) => _FreshReleaseCard(release: releases[index]),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16.0, 24.0, 16.0, 8.0),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _FreshReleaseCard extends StatelessWidget {
  const _FreshReleaseCard({required this.release});

  final FreshRelease release;

  @override
  Widget build(BuildContext context) {
    final cover = release.coverUrl;
    return SizedBox(
      width: 140.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: SizedBox(
                width: 140.0,
                height: 140.0,
                child: cover == null
                    ? const ColoredBox(color: Colors.black12, child: Icon(TablerIcons.disc))
                    : Image.network(
                        cover.toString(),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black12, child: Icon(TablerIcons.disc)),
                      ),
              ),
            ),
            const SizedBox(height: 6.0),
            Text(release.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.0)),
            Text(
              release.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.0, color: Theme.of(context).textTheme.bodySmall?.color),
            ),
          ],
        ),
      ),
    );
  }
}
