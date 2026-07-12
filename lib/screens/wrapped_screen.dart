import 'package:diapason/models/jellyfin_models.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/stats/stats_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class WrappedScreen extends StatefulWidget {
  const WrappedScreen({super.key});

  static const routeName = "/wrapped";

  @override
  State<WrappedScreen> createState() => _WrappedScreenState();
}

class _WrappedScreenState extends State<WrappedScreen> {
  WrappedPeriod _period = WrappedPeriod.thisYear;

  late Future<WrappedData> _data = GetIt.instance<StatsService>().build(_period);

  final _shareKey = GlobalKey();

  bool _sharing = false;

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final boundary = _shareKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;

      final dir = await getTemporaryDirectory();
      final file = File("${dir.path}/diapason-wrapped.png");
      await file.writeAsBytes(bytes.buffer.asUint8List());

      await Share.shareXFiles([XFile(file.path)], text: "My Diapason Wrapped");
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't share that.")));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _playTopTracks(WrappedData data) async {
    final aggregate = GetIt.instance<AggregateBackend>();
    final tracks = <BaseItemDto>[];

    for (final entry in data.topTracks) {
      final matches = await aggregate.getItems(includeItemTypes: "Audio", searchTerm: entry.name, limit: 5);
      final match = matches
          .where((t) => (t.name ?? "").toLowerCase() == entry.name.toLowerCase())
          .firstOrNull;
      if (match != null) tracks.add(match);
    }

    if (!mounted) return;
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Couldn't find those tracks in your library any more.")));
      return;
    }

    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: QueueItemSource(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: "Wrapped — ${_period.displayName}",
        ),
        id: const BaseItemId("wrapped"),
      ),
    );
  }

  void _select(WrappedPeriod period) {
    setState(() {
      _period = period;
      _data = GetIt.instance<StatsService>().build(period);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Your Wrapped"),
        actions: [
          FutureBuilder<WrappedData>(
            future: _data,
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null || data.isEmpty) return const SizedBox.shrink();
              return Row(
                children: [
                  IconButton(
                    tooltip: "Play my top tracks",
                    icon: const Icon(TablerIcons.player_play),
                    onPressed: () => _playTopTracks(data),
                  ),
                  IconButton(
                    tooltip: "Share",
                    icon: _sharing
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(TablerIcons.share),
                    onPressed: _sharing ? null : _share,
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: SegmentedButton<WrappedPeriod>(
              segments: [
                for (final period in WrappedPeriod.values)
                  ButtonSegment(value: period, label: Text(period.displayName)),
              ],
              selected: {_period},
              onSelectionChanged: (selection) => _select(selection.first),
            ),
          ),
          Expanded(
            child: FutureBuilder<WrappedData>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data;
                if (data == null || data.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32.0),
                      child: Text(
                        "Nothing here yet.\n\nPlay some music and your Wrapped will fill in.",
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return RepaintBoundary(key: _shareKey, child: _WrappedBody(data: data));
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WrappedBody extends StatelessWidget {
  const _WrappedBody({required this.data});

  final WrappedData data;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 120.0),
      children: [
        Row(
          children: [
            _Stat(value: "${data.minutesListened}", label: "minutes"),
            _Stat(value: "${data.totalPlays}", label: "tracks played"),
            _Stat(value: "${data.distinctArtists}", label: "artists"),
          ],
        ),
        const SizedBox(height: 8.0),
        Row(
          children: [
            _Stat(value: "${data.streakDays}", label: "day streak"),
            _Stat(value: data.dominantGenre ?? "—", label: "top genre"),
          ],
        ),

        if (data.topTracks.isNotEmpty) _Chart(title: "Top tracks", entries: data.topTracks),
        if (data.topArtists.isNotEmpty) _Chart(title: "Top artists", entries: data.topArtists),
        if (data.topAlbums.isNotEmpty) _Chart(title: "Top albums", entries: data.topAlbums),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
          child: Column(
            children: [
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4.0),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({required this.title, required this.entries});

  final String title;
  final List<WrappedEntry> entries;

  @override
  Widget build(BuildContext context) {
    final max = entries.first.plays;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 24.0, 0, 8.0),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final (index, entry) in entries.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Row(
              children: [
                SizedBox(
                  width: 24.0,
                  child: Text(
                    "${index + 1}",
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (entry.subtitle.isNotEmpty)
                        Text(
                          entry.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      const SizedBox(height: 4.0),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3.0),
                        child: LinearProgressIndicator(
                          value: entry.plays / max,
                          minHeight: 6.0,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12.0),
                Text("${entry.plays}", style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
      ],
    );
  }
}

class WrappedTile extends StatelessWidget {
  const WrappedTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(TablerIcons.chart_bar),
    title: const Text("Your Wrapped"),
    subtitle: const Text("What you actually listened to"),
    onTap: () => Navigator.of(context).pushNamed(WrappedScreen.routeName),
  );
}
