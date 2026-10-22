import 'dart:async';

import 'package:diapason/components/AlbumScreen/download_button.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/discovery/youtube_discover_service.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/components/MusicScreen/youtube_upload_button.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class YouTubeActions {
  static QueueItemSource _source(BaseItemDto anchor, String name) => QueueItemSource(
    type: QueueItemSourceType.unknown,
    name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: name),
    id: anchor.id,
  );

  static void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  static Future<void> play(
    BuildContext context,
    List<BaseItemDto> tracks, {
    int index = 0,
    String name = "YouTube",
  }) async {
    try {
      await GetIt.instance<QueueService>().startPlayback(
        items: tracks,
        startingIndex: index,
        source: _source(tracks[index], name),
      );
    } catch (e, stack) {
      _toast(context, "Couldn't play that. ${FriendlyError.reportGlobal("Play YouTube track", e, stack)}");
    }
  }

  static Future<void> discover(BuildContext context, BaseItemDto track) async {
    _toast(context, "Building a discover queue from '${track.name ?? "this track"}'…");
    try {
      final queue = await GetIt.instance<YouTubeDiscoverService>().radioFromSeed(track);
      if (queue.isEmpty) {
        _toast(context, "Nothing to discover from that track.");
        return;
      }
      await GetIt.instance<QueueService>().startPlayback(
        items: queue,
        source: _source(track, "YouTube Discover · ${track.name ?? ""}".trim()),
      );
      _toast(context, "Discovering ${queue.length} tracks");
    } catch (e, stack) {
      _toast(context, "Couldn't start discover. ${FriendlyError.reportGlobal("YouTube discover", e, stack)}");
    }
  }

  static String duration(Duration? duration) {
    if (duration == null) return "";
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, "0");
    return "${duration.inMinutes}:$seconds";
  }
}

class YouTubeThumbnail extends StatelessWidget {
  const YouTubeThumbnail(this.track, {super.key, this.width, this.height, this.fit = BoxFit.cover});

  final BaseItemDto track;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final youtube = GetIt.instance<YouTubeService>();
    final url = youtube.thumbnail(track);
    const fallback = Icon(TablerIcons.brand_youtube);
    if (url == null) return SizedBox(width: width, height: height, child: fallback);
    return SizedBox(
      width: width,
      height: height,
      child: Image.network(
        url.toString(),
        headers: youtube.imageHeaders.isEmpty ? null : youtube.imageHeaders,
        fit: fit,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class YouTubeTrackTile extends StatelessWidget {
  const YouTubeTrackTile({super.key, required this.track, required this.onPlay, this.onDiscover});

  final BaseItemDto track;
  final VoidCallback onPlay;
  final VoidCallback? onDiscover;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: YouTubeThumbnail(track, width: 56.0, height: 40.0),
      title: Text(track.name ?? "Unknown", maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(track.albumArtist ?? "Unknown", maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(YouTubeActions.duration(track.runTimeTicksDuration())),
          if (onDiscover != null)
            IconButton(icon: const Icon(TablerIcons.radio), tooltip: "Start discover queue", onPressed: onDiscover),
          if (YouTubeUploadButton.handles(track))
            YouTubeUploadButton(track: track)
          else
            DownloadButton(
              item: DownloadStub.fromItem(type: DownloadItemType.track, item: track),
            ),
        ],
      ),
      onTap: onPlay,
    );
  }
}

class YouTubeSearchResults extends StatefulWidget {
  const YouTubeSearchResults({super.key, required this.query, this.debounce = const Duration(milliseconds: 600)});

  final String query;
  final Duration debounce;

  @override
  State<YouTubeSearchResults> createState() => _YouTubeSearchResultsState();
}

class _YouTubeSearchResultsState extends State<YouTubeSearchResults> {
  Timer? _timer;
  List<BaseItemDto> _results = const [];
  bool _loading = false;
  String? _error;
  ErrorSource _errorSource = ErrorSource.unknown;
  String _loadedFor = "";
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _schedule(immediately: true);
  }

  @override
  void didUpdateWidget(YouTubeSearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule({bool immediately = false}) {
    _timer?.cancel();
    final query = widget.query.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
        _loadedFor = "";
      });
      return;
    }
    setState(() => _loading = true);
    _timer = Timer(immediately ? Duration.zero : widget.debounce, () => _run(query));
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    try {
      final results = await GetIt.instance<YouTubeService>().search(query, throwOnError: true);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _error = null;
        _loading = false;
        _loadedFor = query;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = const [];
        _error = FriendlyError.message(e);
        _errorSource = FriendlyError.describe(e).source;
        _loading = false;
        _loadedFor = query;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.query.trim().isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(32), child: Text("Type to search YouTube.")),
      );
    }
    if (_loading && _results.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(TablerIcons.alert_triangle, size: 32),
              const SizedBox(height: 8),
              Chip(label: Text("Problem: ${_errorSource.label}"), visualDensity: VisualDensity.compact),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => _run(widget.query.trim()), child: const Text("Try again")),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty && _loadedFor.isNotEmpty) return const Center(child: Text("No results."));

    return Stack(
      children: [
        ListView.builder(
          itemCount: _results.length,
          itemBuilder: (context, index) {
            final track = _results[index];
            return YouTubeTrackTile(
              track: track,
              onPlay: () =>
                  YouTubeActions.play(context, _results, index: index, name: "YouTube · ${widget.query.trim()}"),
              onDiscover: () => YouTubeActions.discover(context, track),
            );
          },
        ),
        if (_loading) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
      ],
    );
  }
}

class YouTubeHome extends StatefulWidget {
  const YouTubeHome({super.key});

  @override
  State<YouTubeHome> createState() => _YouTubeHomeState();
}

class _YouTubeHomeState extends State<YouTubeHome> {
  late Future<List<YouTubeShelf>> _shelves = GetIt.instance<YouTubeService>().homeShelves();

  Future<void> _refresh() async {
    final next = GetIt.instance<YouTubeService>().homeShelves(refresh: true);
    setState(() => _shelves = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<YouTubeShelf>>(
      future: _shelves,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final shelves = snapshot.data ?? const [];
        if (shelves.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              children: const [
                Padding(
                  padding: EdgeInsets.all(32.0),
                  child: Text(
                    "Couldn't load recommendations right now.\nPull down to retry, or search above.",
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24.0),
            children: [for (final shelf in shelves) _Shelf(shelf: shelf)],
          ),
        );
      },
    );
  }
}

class _Shelf extends StatelessWidget {
  const _Shelf({required this.shelf});

  final YouTubeShelf shelf;

  static const _cardWidth = 168.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 12.0, 8.0, 4.0),
          child: Row(
            children: [
              Expanded(child: Text(shelf.title, style: theme.textTheme.titleMedium)),
              IconButton(
                icon: const Icon(TablerIcons.player_play),
                tooltip: "Play all",
                onPressed: () => YouTubeActions.play(context, shelf.tracks, name: shelf.title),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 170.0,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            itemCount: shelf.tracks.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12.0),
            itemBuilder: (context, index) {
              final track = shelf.tracks[index];
              return InkWell(
                borderRadius: BorderRadius.circular(8.0),
                onTap: () => YouTubeActions.play(context, shelf.tracks, index: index, name: shelf.title),
                onLongPress: () => YouTubeActions.discover(context, track),
                child: SizedBox(
                  width: _cardWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8.0),
                        child: YouTubeThumbnail(track, width: _cardWidth, height: _cardWidth * 9 / 16),
                      ),
                      const SizedBox(height: 6.0),
                      Text(
                        track.name ?? "Unknown",
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      Text(
                        track.albumArtist ?? "",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class SearchSourceSwitcher extends StatelessWidget {
  const SearchSourceSwitcher({super.key, required this.youtube, required this.onChanged});

  final bool youtube;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 4.0),
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, icon: Icon(TablerIcons.books), label: Text("Library")),
          ButtonSegment(value: true, icon: Icon(TablerIcons.brand_youtube), label: Text("YouTube")),
        ],
        selected: {youtube},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}
