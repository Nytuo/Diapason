import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/screens/tv/tv_now_playing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class TvHomeScreen extends StatefulWidget {
  const TvHomeScreen({super.key});

  static const routeName = "/tv";

  @override
  State<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends State<TvHomeScreen> {
  late Future<List<BaseItemDto>> _albums;
  late Future<List<BaseItemDto>> _artists;

  final _searchController = TextEditingController();
  Future<List<BaseItemDto>>? _searchResults;

  @override
  void initState() {
    super.initState();
    final aggregate = GetIt.instance<AggregateBackend>();
    _albums = aggregate.getItems(includeItemTypes: "MusicAlbum", limit: 40);
    _artists = aggregate.getItems(includeItemTypes: "MusicArtist", limit: 40);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _search(String query) {
    setState(() {
      _searchResults = query.trim().isEmpty
          ? null
          : GetIt.instance<AggregateBackend>().getItems(searchTerm: query, includeItemTypes: "Audio", limit: 40);
    });
  }

  Future<void> _play(BaseItemDto item) async {
    final aggregate = GetIt.instance<AggregateBackend>();

    final tracks = item.type == "Audio" ? [item] : await aggregate.getItems(parentItem: item);
    if (tracks.isEmpty || !mounted) return;

    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: QueueItemSource(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: item.name ?? "Diapason",
        ),
        id: item.id,
      ),
    );

    if (mounted) {
      await Navigator.of(context).pushNamed(TvNowPlayingScreen.routeName);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 48.0, vertical: 32.0),
          children: [
            Row(
              children: [
                Text(
                  "Diapason",
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white),
                ),
                const SizedBox(width: 48.0),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 20.0),
                    textInputAction: TextInputAction.search,
                    onSubmitted: _search,
                    decoration: const InputDecoration(
                      hintText: "Search",
                      hintStyle: TextStyle(color: Colors.white54),
                      prefixIcon: Icon(TablerIcons.search, color: Colors.white54),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 24.0),
                _TvButton(
                  icon: TablerIcons.player_play,
                  label: "Now playing",
                  onPressed: () => Navigator.of(context).pushNamed(TvNowPlayingScreen.routeName),
                ),
              ],
            ),

            if (_searchResults != null) _TvRow(title: "Results", items: _searchResults!, onPlay: _play),

            _TvRow(title: "Albums", items: _albums, onPlay: _play),
            _TvRow(title: "Artists", items: _artists, onPlay: _play),
          ],
        ),
      ),
    );
  }
}

class _TvRow extends StatelessWidget {
  const _TvRow({required this.title, required this.items, required this.onPlay});

  final String title;
  final Future<List<BaseItemDto>> items;
  final void Function(BaseItemDto) onPlay;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<BaseItemDto>>(
      future: items,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(padding: EdgeInsets.all(32.0), child: LinearProgressIndicator());
        }
        final results = snapshot.data ?? const [];
        if (results.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 32.0, 0, 12.0),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white),
              ),
            ),
            SizedBox(
              height: 220.0,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: results.length,
                itemBuilder: (context, index) => _TvCard(item: results[index], onPlay: onPlay),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TvCard extends StatefulWidget {
  const _TvCard({required this.item, required this.onPlay});

  final BaseItemDto item;
  final void Function(BaseItemDto) onPlay;

  @override
  State<_TvCard> createState() => _TvCardState();
}

class _TvCardState extends State<_TvCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Focus(
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onPlay(widget.item);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: () => widget.onPlay(widget.item),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 160.0,
          margin: const EdgeInsets.only(right: 16.0),
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8.0),
            color: _focused ? accent.withValues(alpha: 0.25) : Colors.white10,
            border: Border.all(color: _focused ? accent : Colors.transparent, width: 3.0),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: Icon(
                    widget.item.type == "MusicArtist" ? TablerIcons.microphone_2 : TablerIcons.disc,
                    size: 56.0,
                    color: Colors.white70,
                  ),
                ),
              ),
              const SizedBox(height: 8.0),
              Text(
                widget.item.name ?? "Unknown",
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15.0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvButton extends StatefulWidget {
  const _TvButton({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<_TvButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Focus(
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 14.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8.0),
            color: _focused ? accent : Colors.white10,
          ),
          child: Row(
            children: [
              Icon(widget.icon, color: Colors.white),
              const SizedBox(width: 8.0),
              Text(widget.label, style: const TextStyle(color: Colors.white, fontSize: 16.0)),
            ],
          ),
        ),
      ),
    );
  }
}
