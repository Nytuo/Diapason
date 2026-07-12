import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});

  static const routeName = "/radio";

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  late Future<List<BaseItemDto>> _stations = GetIt.instance<AggregateBackend>().getRadioStations();

  Future<void> _play(BaseItemDto station) async {
    try {
      await GetIt.instance<QueueService>().startPlayback(
        items: [station],
        source: QueueItemSource(
          type: QueueItemSourceType.unknown,
          name: QueueItemSourceName(
            type: QueueItemSourceNameType.preTranslated,
            pretranslatedName: station.name ?? "Radio",
          ),
          id: station.id,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't tune in: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Radio"),
        actions: [
          IconButton(
            icon: const Icon(TablerIcons.refresh),
            onPressed: () => setState(() => _stations = GetIt.instance<AggregateBackend>().getRadioStations()),
          ),
        ],
      ),
      body: FutureBuilder<List<BaseItemDto>>(
        future: _stations,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final stations = snapshot.data ?? const [];
          if (stations.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: Text(
                  "No radio stations.\n\nStations come from your Subsonic/Navidrome server — add them there and "
                  "they'll show up here.",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView.builder(
            itemCount: stations.length,
            itemBuilder: (context, index) {
              final station = stations[index];
              return ListTile(
                leading: const Icon(TablerIcons.radio),
                title: Text(station.name ?? "Unknown Station"),
                subtitle: Text(
                  Uri.tryParse(station.path ?? "")?.host ?? "",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(TablerIcons.player_play),
                onTap: () => _play(station),
              );
            },
          );
        },
      ),
    );
  }
}
