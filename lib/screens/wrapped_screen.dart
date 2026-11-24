import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/jellyfin_models.dart';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/components/wrapped_share_card.dart';
import 'package:diapason/services/stats/stats_service.dart';
import 'package:flutter/material.dart';
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

  Future<void> _playTopTracks(WrappedData data) async {
    final aggregate = GetIt.instance<AggregateBackend>();
    final tracks = <BaseItemDto>[];

    for (final entry in data.topTracks) {
      final matches = await aggregate.getItems(includeItemTypes: "Audio", searchTerm: entry.name, limit: 5);
      final match = matches.where((t) => (t.name ?? "").toLowerCase() == entry.name.toLowerCase()).firstOrNull;
      if (match != null) tracks.add(match);
    }

    if (!mounted) return;
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.wrappedNoTracks)));
      return;
    }

    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: QueueItemSource(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: AppLocalizations.of(context)!.wrappedQueueName(_period.displayName),
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
        title: Text(AppLocalizations.of(context)!.wrappedTitle),
        actions: [
          FutureBuilder<WrappedData>(
            future: _data,
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null || data.isEmpty) return const SizedBox.shrink();
              return Row(
                children: [
                  IconButton(
                    tooltip: AppLocalizations.of(context)!.wrappedPlayTop,
                    icon: const Icon(TablerIcons.player_play),
                    onPressed: () => _playTopTracks(data),
                  ),
                  IconButton(
                    tooltip: AppLocalizations.of(context)!.wrappedShareImage,
                    icon: const Icon(TablerIcons.share),
                    onPressed: () => showWrappedSharePreview(context, data),
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
                  return Center(
                    child: Padding(
                      padding: EdgeInsets.all(32.0),
                      child: Text(AppLocalizations.of(context)!.wrappedEmpty, textAlign: TextAlign.center),
                    ),
                  );
                }
                return _WrappedBody(data: data);
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
            _Stat(value: "${data.minutesListened}", label: AppLocalizations.of(context)!.wrappedStatMinutes),
            _Stat(value: "${data.totalPlays}", label: AppLocalizations.of(context)!.wrappedStatPlays),
            _Stat(value: "${data.distinctArtists}", label: AppLocalizations.of(context)!.wrappedStatArtists),
          ],
        ),
        const SizedBox(height: 8.0),
        Row(
          children: [
            _Stat(value: "${data.streakDays}", label: AppLocalizations.of(context)!.wrappedStatStreak),
            _Stat(value: data.dominantGenre ?? "—", label: AppLocalizations.of(context)!.wrappedStatGenre),
          ],
        ),

        if (data.topTracks.isNotEmpty)
          _Chart(title: AppLocalizations.of(context)!.wrappedTopTracks, entries: data.topTracks),
        if (data.topArtists.isNotEmpty)
          _Chart(title: AppLocalizations.of(context)!.wrappedTopArtists, entries: data.topArtists),
        if (data.topAlbums.isNotEmpty)
          _Chart(title: AppLocalizations.of(context)!.wrappedTopAlbums, entries: data.topAlbums),
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
              Text(label, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
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
                SizedBox(width: 24.0, child: Text("${index + 1}", style: Theme.of(context).textTheme.bodySmall)),
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
                        child: LinearProgressIndicator(value: entry.plays / max, minHeight: 6.0),
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
    title: Text(AppLocalizations.of(context)!.wrappedTitle),
    subtitle: Text(AppLocalizations.of(context)!.wrappedSubtitle),
    onTap: () => Navigator.of(context).pushNamed(WrappedScreen.routeName),
  );
}
