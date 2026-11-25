import 'dart:async';

import 'package:diapason/components/connect_devices.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/screens/watch/watch_screen.dart';
import 'package:diapason/screens/watch/watch_widgets.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/watch_connect_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _log = Logger("WatchLibrary");

WatchConnectController get _watch => GetIt.instance<WatchConnectController>();

String _deviceName() => connectDisplayName(_watch.device.value?.name ?? "");

/// The library menu: recent, favorites, albums, artists, playlists and search, from the device or the watch.
class WatchLibraryScreen extends StatefulWidget {
  const WatchLibraryScreen({super.key});

  @override
  State<WatchLibraryScreen> createState() => _WatchLibraryScreenState();
}

class _WatchLibraryScreenState extends State<WatchLibraryScreen> {
  WatchLibrarySource? _source = _watch.defaultLibrarySource;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final source = _source;
    if (_watch.device.value == null) return WatchListPage(children: [WatchMessage(l10n.watchNotConnected)]);
    if (source == null) {
      return WatchListPage(
        title: l10n.watchLibrary,
        children: [WatchMessage(l10n.watchLibraryUnavailable(_deviceName()))],
      );
    }
    final both = _watch.deviceBrowsable && _watch.hasOwnSources;

    void open(String title, ConnectBrowseView view) => pushWatchPage<void>(
      context,
      WatchBrowsePage(source: source, title: title, request: ConnectBrowseRequest(view)),
    );

    return WatchListPage(
      title: l10n.watchLibrary,
      children: [
        if (both)
          WatchTile(
            icon: source == WatchLibrarySource.device ? TablerIcons.device_speaker : TablerIcons.device_watch,
            title: source == WatchLibrarySource.device ? l10n.watchSourceDevice(_deviceName()) : l10n.watchSourceWatch,
            selected: true,
            onTap: () => setState(
              () =>
                  _source = source == WatchLibrarySource.device ? WatchLibrarySource.watch : WatchLibrarySource.device,
            ),
          ),
        WatchTile(
          icon: TablerIcons.search,
          title: l10n.watchSearch,
          onTap: () => pushWatchPage<void>(context, WatchSearchPage(source: source)),
        ),
        WatchTile(
          icon: TablerIcons.history,
          title: l10n.watchRecent,
          onTap: () => open(l10n.watchRecent, ConnectBrowseView.recent),
        ),
        WatchTile(
          icon: TablerIcons.heart,
          title: l10n.watchFavorites,
          onTap: () => open(l10n.watchFavorites, ConnectBrowseView.favorites),
        ),
        WatchTile(
          icon: TablerIcons.disc,
          title: l10n.watchAlbums,
          onTap: () => open(l10n.watchAlbums, ConnectBrowseView.albums),
        ),
        WatchTile(
          icon: TablerIcons.microphone_2,
          title: l10n.watchArtists,
          onTap: () => open(l10n.watchArtists, ConnectBrowseView.artists),
        ),
        WatchTile(
          icon: TablerIcons.playlist,
          title: l10n.watchPlaylists,
          onTap: () => open(l10n.watchPlaylists, ConnectBrowseView.playlists),
        ),
      ],
    );
  }
}

/// A listing, loaded a page at a time as it is scrolled. A container opens its contents; a track asks what to do.
class WatchBrowsePage extends StatefulWidget {
  const WatchBrowsePage({super.key, required this.source, required this.title, required this.request, this.parent});

  final WatchLibrarySource source;
  final String title;
  final ConnectBrowseRequest request;

  /// The container being listed, which gets Play and Shuffle buttons on top.
  final ConnectBrowseItem? parent;

  @override
  State<WatchBrowsePage> createState() => _WatchBrowsePageState();
}

class _WatchBrowsePageState extends State<WatchBrowsePage> {
  final List<ConnectBrowseItem> _items = [];
  bool _loading = false;
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final r = widget.request;
    final page = await _watch.browse(
      widget.source,
      ConnectBrowseRequest(r.view, parentId: r.parentId, query: r.query, start: _items.length, limit: r.limit),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (page == null) {
        _failed = true;
      } else {
        _items.addAll(page);
        // Search answers everything at once; other views stop when a page comes back short.
        _done = r.view == ConnectBrowseView.search || page.length < r.limit;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final parent = widget.parent;
    return WatchListPage(
      title: widget.title,
      onEndReached: _done || _failed ? null : _loadMore,
      children: [
        if (parent != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              WatchRoundButton(
                icon: TablerIcons.player_play,
                filled: true,
                tooltip: l10n.watchPlay,
                onPressed: () => sendToDevice(context, widget.source, parent, ConnectPlayMode.play),
              ),
              const SizedBox(width: 12.0),
              WatchRoundButton(
                icon: TablerIcons.arrows_shuffle,
                tooltip: l10n.watchShuffle,
                onPressed: () => sendToDevice(context, widget.source, parent, ConnectPlayMode.shuffle),
              ),
              const SizedBox(width: 12.0),
              WatchRoundButton(
                icon: TablerIcons.dots,
                tooltip: l10n.watchAddToQueue,
                onPressed: () => showItemActions(context, widget.source, parent),
              ),
            ],
          ),
        if (parent != null) const SizedBox(height: 6.0),
        for (final item in _items) WatchBrowseTile(source: widget.source, item: item, siblings: _items),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Center(child: SizedBox.square(dimension: 22.0, child: CircularProgressIndicator(strokeWidth: 2.0))),
          )
        else if (_failed) ...[
          WatchMessage(l10n.watchLoadFailed),
          WatchTile(icon: TablerIcons.refresh, title: l10n.watchRetry, onTap: _loadMore),
        ] else if (_items.isEmpty)
          WatchMessage(l10n.watchEmptyList),
      ],
    );
  }
}

/// One row of a listing.
class WatchBrowseTile extends StatelessWidget {
  const WatchBrowseTile({super.key, required this.source, required this.item, this.siblings});

  final WatchLibrarySource source;
  final ConnectBrowseItem item;
  final List<ConnectBrowseItem>? siblings;

  IconData get _fallback => switch (item.type) {
    ConnectBrowseItem.album => TablerIcons.disc,
    ConnectBrowseItem.artist => TablerIcons.microphone_2,
    ConnectBrowseItem.playlist => TablerIcons.playlist,
    _ => TablerIcons.music,
  };

  @override
  Widget build(BuildContext context) {
    return WatchTile(
      leading: _ItemArt(source: source, item: item, fallback: _fallback),
      title: item.title,
      subtitle: item.subtitle,
      onTap: () {
        if (item.isContainer) {
          pushWatchPage<void>(
            context,
            WatchBrowsePage(
              source: source,
              title: item.title,
              parent: item.type == ConnectBrowseItem.artist ? null : item,
              request: ConnectBrowseRequest(ConnectBrowseView.children, parentId: item.id),
            ),
          );
        } else {
          showItemActions(context, source, item, siblings: siblings);
        }
      },
      onLongPress: () => showItemActions(context, source, item, siblings: siblings),
    );
  }
}

class _ItemArt extends StatelessWidget {
  const _ItemArt({required this.source, required this.item, required this.fallback});

  final WatchLibrarySource source;
  final ConnectBrowseItem item;
  final IconData fallback;

  @override
  Widget build(BuildContext context) {
    if (source == WatchLibrarySource.device || !item.hasArt) {
      return WatchArt(url: _watch.artUrlOf(source, item), fallback: fallback);
    }
    return FutureBuilder(
      future: _watch.ownArtOf(item),
      builder: (context, snapshot) =>
          WatchArt(url: snapshot.data?.url, headers: snapshot.data?.headers, fallback: fallback),
    );
  }
}

/// Play, shuffle, play next or add to queue: what to do with [item] on the device.
Future<void> showItemActions(
  BuildContext context,
  WatchLibrarySource source,
  ConnectBrowseItem item, {
  List<ConnectBrowseItem>? siblings,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final mode = await pushWatchPage<ConnectPlayMode>(
    context,
    WatchListPage(
      title: item.title,
      children: [
        for (final (mode, icon, label) in [
          (ConnectPlayMode.play, TablerIcons.player_play, l10n.watchPlay),
          if (!item.isTrack) (ConnectPlayMode.shuffle, TablerIcons.arrows_shuffle, l10n.watchShuffle),
          (ConnectPlayMode.next, TablerIcons.corner_down_right, l10n.watchPlayNext),
          (ConnectPlayMode.queue, TablerIcons.playlist_add, l10n.watchAddToQueue),
        ])
          Builder(
            builder: (context) => WatchTile(icon: icon, title: label, onTap: () => Navigator.of(context).pop(mode)),
          ),
      ],
    ),
  );
  if (mode == null || !context.mounted) return;
  await sendToDevice(context, source, item, mode, siblings: siblings);
}

/// Sends [item] to the controlled device and says whether it got there.
Future<void> sendToDevice(
  BuildContext context,
  WatchLibrarySource source,
  ConnectBrowseItem item,
  ConnectPlayMode mode, {
  List<ConnectBrowseItem>? siblings,
}) async {
  final l10n = AppLocalizations.of(context)!;
  bool ok;
  try {
    ok = await _watch.send(source, item, mode, siblings: siblings);
  } catch (e) {
    _log.warning("Could not send '${item.title}' to the device: $e");
    ok = false;
  }
  if (!context.mounted) return;
  watchToast(context, ok ? l10n.watchSent(_deviceName()) : l10n.watchSendFailed);
  // Playing something replaces what is on screen: go back to it.
  if (ok && (mode == ConnectPlayMode.play || mode == ConnectPlayMode.shuffle)) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

/// Search box (the watch's keyboard or voice input) and its results.
class WatchSearchPage extends StatefulWidget {
  const WatchSearchPage({super.key, required this.source});

  final WatchLibrarySource source;

  @override
  State<WatchSearchPage> createState() => _WatchSearchPageState();
}

class _WatchSearchPageState extends State<WatchSearchPage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    pushWatchPage<void>(
      context,
      WatchBrowsePage(
        source: widget.source,
        title: q,
        request: ConnectBrowseRequest(ConnectBrowseView.search, query: q),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return WatchListPage(
      title: l10n.watchSearch,
      children: [
        TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          style: const TextStyle(color: WatchColors.text, fontSize: 14.0),
          decoration: InputDecoration(
            filled: true,
            fillColor: WatchColors.surface,
            hintText: l10n.watchSearch,
            hintStyle: const TextStyle(color: WatchColors.secondary),
            prefixIcon: const Icon(TablerIcons.search, color: WatchColors.secondary, size: 18.0),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(26.0), borderSide: BorderSide.none),
          ),
        ),
        const SizedBox(height: 8.0),
        WatchTile(icon: TablerIcons.arrow_right, title: l10n.watchSearch, onTap: () => _submit(_text.text)),
      ],
    );
  }
}
