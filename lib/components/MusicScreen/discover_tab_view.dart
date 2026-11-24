import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/components/MusicScreen/similar_artists_section.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/discover_playlist_screen.dart';
import 'package:diapason/screens/scrobbling_settings_screen.dart';
import 'package:diapason/services/discovery/discovery_service.dart';
import 'package:diapason/services/discovery/youtube_discover_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
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
  Future<List<DiscoverPlaylist>>? _yourPlaylists;
  Future<List<DiscoverPlaylist>>? _madeForYou;

  String? _importing;
  String? _discovering;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  void _loadPlaylists() {
    if (FinampSettingsHelper.finampSettings.listenBrainzToken.isEmpty) return;
    setState(() {
      _yourPlaylists = _withUsername(_discovery.listenBrainzUserPlaylists);
      _madeForYou = _withUsername(_discovery.listenBrainzCreatedForYou);
    });
  }

  Future<List<DiscoverPlaylist>> _withUsername(Future<List<DiscoverPlaylist>> Function(String) load) async {
    final username = await _discovery.listenBrainzUsername() ?? FinampSettingsHelper.finampSettings.lastFmUsername;
    if (username.isEmpty) return const [];
    return load(username);
  }

  Future<void> _playPlaylist(DiscoverPlaylist playlist) async {
    setState(() => _importing = playlist.id);
    try {
      final recommended = await _discovery.discoverPlaylistTracks(playlist);
      final tracks = await _discovery.resolve(recommended);

      if (!mounted) return;
      if (tracks.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.discoverNoMatch)));
        return;
      }

      await GetIt.instance<QueueService>().startPlayback(
        items: tracks,
        source: QueueItemSource(
          type: QueueItemSourceType.unknown,
          name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: playlist.title),
          id: BaseItemId(playlist.id),
        ),
      );

      if (mounted) {
        final matched = tracks.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.discoverPlayingCount(matched, recommended.length))),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  Future<void> _discoverFromPlaylist(DiscoverPlaylist playlist) async {
    setState(() => _discovering = playlist.id);
    try {
      final recommended = await _discovery.discoverPlaylistTracks(playlist);
      final resolved = await _discovery.resolve(recommended);
      if (!mounted) return;

      final queue = await GetIt.instance<YouTubeDiscoverService>().radioFromPlaylistTail(resolved);
      if (!mounted) return;
      if (queue.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.discoverQueueFailed)));
        return;
      }

      await GetIt.instance<QueueService>().startPlayback(
        items: queue,
        source: QueueItemSource(
          type: QueueItemSourceType.unknown,
          name: QueueItemSourceName(
            type: QueueItemSourceNameType.preTranslated,
            pretranslatedName: AppLocalizations.of(context)!.discoverQueueName(playlist.title),
          ),
          id: BaseItemId(playlist.id),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.discoverDiscoveringCount(queue.length))));
      }
    } finally {
      if (mounted) setState(() => _discovering = null);
    }
  }

  Widget _playlistTile(DiscoverPlaylist playlist) {
    final busy = _importing != null || _discovering != null;
    return ListTile(
      leading: const Icon(TablerIcons.playlist),
      title: Text(playlist.title),
      subtitle: playlist.subtitle == null ? null : Text(playlist.subtitle!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_discovering == playlist.id)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else if (ref.watch(youTubeAvailableProvider))
            IconButton(
              icon: const Icon(TablerIcons.radio),
              tooltip: AppLocalizations.of(context)!.discoverContinueYoutube,
              onPressed: busy ? null : () => _discoverFromPlaylist(playlist),
            ),
          if (_importing == playlist.id)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else
            IconButton(
              icon: const Icon(TablerIcons.player_play),
              tooltip: AppLocalizations.of(context)!.discoverPlayAll,
              onPressed: busy ? null : () => _playPlaylist(playlist),
            ),
          const Icon(TablerIcons.chevron_right),
        ],
      ),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => DiscoverPlaylistScreen(playlist: playlist))),
    );
  }

  Widget _playlistSection(String title, Future<List<DiscoverPlaylist>> future) {
    return FutureBuilder<List<DiscoverPlaylist>>(
      future: future,
      builder: (context, snapshot) {
        final playlists = snapshot.data;
        if (playlists == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionHeader(title),
              const Padding(padding: EdgeInsets.all(16.0), child: LinearProgressIndicator()),
            ],
          );
        }
        if (playlists.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_SectionHeader(title), for (final playlist in playlists) _playlistTile(playlist)],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(finampSettingsProvider.listenBrainzToken).isNotEmpty;
    final lastFmConnected = ref.watch(finampSettingsProvider.lastFmApiKey).isNotEmpty;

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
                title: Text(AppLocalizations.of(context)!.discoverConnectLb),
                subtitle: Text(AppLocalizations.of(context)!.discoverConnectLbSubtitle),
                trailing: const Icon(TablerIcons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(ScrobblingSettingsScreen.routeName),
              ),
            ),

          if (!lastFmConnected)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12.0),
              child: ListTile(
                leading: const Icon(TablerIcons.chart_bar),
                title: Text(AppLocalizations.of(context)!.discoverAddLfmKey),
                subtitle: Text(AppLocalizations.of(context)!.discoverAddLfmKeySubtitle),
                trailing: const Icon(TablerIcons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(ScrobblingSettingsScreen.routeName),
              ),
            ),

          if (_madeForYou != null)
            _playlistSection(AppLocalizations.of(context)!.discoverMadeForYouSection, _madeForYou!),

          if (_yourPlaylists != null)
            _playlistSection(AppLocalizations.of(context)!.discoverYourPlaylists, _yourPlaylists!),

          Builder(
            builder: (context) {
              final genres = _discovery.lastFmGenrePlaylists();
              if (genres.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionHeader(AppLocalizations.of(context)!.discoverChartsGenres),
                  for (final playlist in genres) _playlistTile(playlist),
                ],
              );
            },
          ),

          const SimilarToNowPlaying(),

          _SectionHeader(AppLocalizations.of(context)!.discoverFreshReleases),
          FutureBuilder<List<FreshRelease>>(
            future: _fresh,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(padding: EdgeInsets.all(16.0), child: LinearProgressIndicator());
              }
              final releases = snapshot.data ?? const [];
              if (releases.isEmpty) {
                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text(AppLocalizations.of(context)!.discoverLbUnreachable),
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
                        // Cover Art Archive serves full-size scans; decode at tile size instead.
                        cacheWidth: (140.0 * MediaQuery.devicePixelRatioOf(context)).round(),
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: Colors.black12, child: Icon(TablerIcons.disc)),
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
