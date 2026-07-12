import 'package:diapason/components/AlbumScreen/download_button.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class YouTubeTabView extends StatefulWidget {
  const YouTubeTabView({super.key});

  @override
  State<YouTubeTabView> createState() => _YouTubeTabViewState();
}

class _YouTubeTabViewState extends State<YouTubeTabView> {
  final _query = TextEditingController();

  List<BaseItemDto> _results = const [];
  bool _searching = false;
  bool _searched = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _searching = true;
      _searched = true;
    });
    final results = await GetIt.instance<YouTubeService>().search(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  Future<void> _play(BaseItemDto track) async {
    try {
      await GetIt.instance<QueueService>().startPlayback(
        items: [track],
        source: QueueItemSource(
          type: QueueItemSourceType.unknown,
          name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "YouTube"),
          id: track.id,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't play that: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: "Search YouTube",
              prefixIcon: const Icon(TablerIcons.search),
              suffixIcon: IconButton(icon: const Icon(TablerIcons.arrow_right), onPressed: _search),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_searching) return const Center(child: CircularProgressIndicator());

    if (!_searched) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: Text("Find music that isn't in your libraries.", textAlign: TextAlign.center),
        ),
      );
    }

    if (_results.isEmpty) {
      return const Center(child: Text("No results."));
    }

    final youtube = GetIt.instance<YouTubeService>();
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final track = _results[index];
        final thumbnail = youtube.thumbnail(track);
        return ListTile(
          leading: thumbnail == null
              ? const Icon(TablerIcons.brand_youtube)
              : SizedBox(
                  width: 56.0,
                  child: Image.network(
                    thumbnail.toString(),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(TablerIcons.brand_youtube),
                  ),
                ),
          title: Text(track.name ?? "Unknown", maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            track.albumArtist ?? "Unknown",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_duration(track.runTimeTicksDuration())),
              DownloadButton(item: DownloadStub.fromItem(type: DownloadItemType.track, item: track)),
            ],
          ),
          onTap: () => _play(track),
        );
      },
    );
  }

  static String _duration(Duration? duration) {
    if (duration == null) return "";
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, "0");
    return "$minutes:$seconds";
  }
}
