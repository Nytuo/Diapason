import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/artist_screen.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/discovery/discovery_service.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class SimilarArtistsSection extends StatefulWidget {
  const SimilarArtistsSection({super.key, required this.seedArtist});

  final String seedArtist;

  @override
  State<SimilarArtistsSection> createState() => _SimilarArtistsSectionState();
}

class _SimilarArtistsSectionState extends State<SimilarArtistsSection> {
  late Future<List<({String name, double match})>> _similar =
      GetIt.instance<DiscoveryService>().similarArtists(widget.seedArtist);

  @override
  void didUpdateWidget(SimilarArtistsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seedArtist != widget.seedArtist) {
      _similar = GetIt.instance<DiscoveryService>().similarArtists(widget.seedArtist);
    }
  }

  Future<void> _open(String name) async {
    final discovery = GetIt.instance<DiscoveryService>();

    final owned = await discovery.findArtist(name);
    if (owned != null && mounted) {
      await Navigator.of(context).pushNamed(ArtistScreen.routeName, arguments: owned);
      return;
    }

    final tracks = await discovery.resolve([
      DiscoveredTrack(title: name, artist: name),
    ], youtubeFallback: true);

    if (!mounted) return;
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't find anything by $name.")));
      return;
    }

    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: QueueItemSource(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: name),
        id: tracks.first.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<({String name, double match})>>(
      future: _similar,
      builder: (context, snapshot) {
        final similar = snapshot.data ?? const [];
        if (similar.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                "Artists like ${widget.seedArtist}",
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: similar.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(
                    avatar: const Icon(TablerIcons.microphone_2, size: 16),
                    label: Text(similar[index].name),
                    onPressed: () => _open(similar[index].name),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class SimilarToNowPlaying extends StatelessWidget {
  const SimilarToNowPlaying({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FinampQueueInfo?>(
      stream: GetIt.instance<QueueService>().getQueueStream(),
      builder: (context, snapshot) {
        final track = snapshot.data?.currentTrack?.baseItem;
        final artist = track?.albumArtist ?? track?.artists?.firstOrNull;
        if (artist == null || artist.isEmpty) return const SizedBox.shrink();

        return SimilarArtistsSection(seedArtist: artist);
      },
    );
  }
}
