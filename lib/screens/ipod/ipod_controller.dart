import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

enum InterfaceMode {
  modern,
  ipod;

  String get label => this == InterfaceMode.modern ? "Modern" : "iPod Classic";

  static InterfaceMode fromName(String name) =>
      InterfaceMode.values.firstWhere((m) => m.name == name, orElse: () => InterfaceMode.modern);
}

sealed class IpodRowAction {
  const IpodRowAction();
}

class IpodPush extends IpodRowAction {
  const IpodPush({required this.title, required this.loader});

  final String title;
  final Future<List<IpodRow>> Function() loader;
}

class IpodPlay extends IpodRowAction {
  const IpodPlay({required this.tracks, required this.index});

  final List<BaseItemDto> tracks;
  final int index;
}

class IpodNowPlayingAction extends IpodRowAction {
  const IpodNowPlayingAction();
}

class IpodRun extends IpodRowAction {
  const IpodRun(this.effect);

  final void Function() effect;
}

class IpodRow {
  const IpodRow({required this.title, this.subtitle, required this.action});

  final String title;
  final String? subtitle;
  final IpodRowAction action;
}

class IpodScreen extends ChangeNotifier {
  IpodScreen({required this.title, this.isNowPlaying = false, List<IpodRow> rows = const [], this.loader})
    : rows = List.of(rows);

  final String title;
  final bool isNowPlaying;
  final Future<List<IpodRow>> Function()? loader;

  List<IpodRow> rows;
  int selection = 0;
  bool isLoading = false;

  Future<void> loadIfNeeded() async {
    if (loader == null || rows.isNotEmpty || isNowPlaying) return;

    isLoading = true;
    notifyListeners();

    rows = await loader!();
    selection = 0;
    isLoading = false;
    notifyListeners();
  }

  void select(int index) {
    if (index == selection) return;
    selection = index;
    notifyListeners();
  }
}

class IpodController extends ChangeNotifier {
  IpodController() {
    _stack.add(_mainMenu());
  }

  static final _log = Logger("IpodController");

  final List<IpodScreen> _stack = [];

  bool forward = true;

  List<IpodScreen> get stack => List.unmodifiable(_stack);
  IpodScreen get current => _stack.last;

  AggregateBackend get _library => GetIt.instance<AggregateBackend>();
  MusicPlayerBackgroundTask get _player => GetIt.instance<MusicPlayerBackgroundTask>();
  QueueService get _queue => GetIt.instance<QueueService>();

  void _push(IpodScreen screen) {
    forward = true;
    _stack.add(screen);
    notifyListeners();
    screen.loadIfNeeded();
  }

  void scroll(int steps) {
    final screen = current;
    if (screen.isNowPlaying) {
      _scrub(steps);
      return;
    }
    if (screen.rows.isEmpty) return;

    final next = (screen.selection + steps).clamp(0, screen.rows.length - 1);
    screen.select(next);
  }

  void select() {
    final screen = current;
    if (screen.isNowPlaying) {
      playPause();
      return;
    }
    if (screen.selection < 0 || screen.selection >= screen.rows.length) return;
    _activate(screen.rows[screen.selection]);
  }

  void menuBack() {
    if (_stack.length <= 1) return;
    forward = false;
    _stack.removeLast();
    notifyListeners();
  }

  void playPause() {
    (_player.playbackState.valueOrNull?.playing ?? false) ? _player.pause() : _player.play();
  }

  void next() => _player.skipToNext();
  void previous() => _player.skipToPrevious();

  void _scrub(int steps) {
    final duration = _queue.getQueue().currentTrack?.baseItem?.runTimeTicksDuration();
    if (duration == null || duration == Duration.zero) return;

    final position = _player.playbackState.valueOrNull?.position ?? Duration.zero;
    final stepSeconds = (duration.inSeconds / 60).clamp(2, double.infinity);
    final target = position + Duration(seconds: (steps * stepSeconds).round());

    _player.seek(Duration(milliseconds: target.inMilliseconds.clamp(0, duration.inMilliseconds)));
  }

  Future<void> _activate(IpodRow row) async {
    switch (row.action) {
      case IpodPush(title: final title, loader: final loader):
        _push(IpodScreen(title: title, loader: loader));

      case IpodPlay(tracks: final tracks, index: final index):
        await _play(tracks, index);
        openNowPlaying();

      case IpodNowPlayingAction():
        openNowPlaying();

      case IpodRun(effect: final effect):
        effect();
    }
  }

  void openNowPlaying() {
    if (current.isNowPlaying) return;
    _push(IpodScreen(title: "Now Playing", isNowPlaying: true));
  }

  Future<void> _play(List<BaseItemDto> tracks, int index) async {
    if (tracks.isEmpty) return;
    try {
      await _queue.startPlayback(
        items: tracks,
        startingIndex: index,
        source: QueueItemSource(
          type: QueueItemSourceType.unknown,
          name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "iPod"),
          id: tracks[index].id,
        ),
      );
    } catch (e) {
      _log.warning("Could not play from the iPod menu: $e");
    }
  }

  IpodScreen _mainMenu() => IpodScreen(
    title: "iPod",
    rows: [
      IpodRow(title: "Playlists", action: IpodPush(title: "Playlists", loader: _playlistRows)),
      IpodRow(title: "Artists", action: IpodPush(title: "Artists", loader: _artistRows)),
      IpodRow(title: "Albums", action: IpodPush(title: "Albums", loader: _albumRows)),
      IpodRow(title: "Songs", action: IpodPush(title: "Songs", loader: _songMenuRows)),
      IpodRow(title: "Shuffle Songs", action: IpodRun(_shuffleAll)),
      const IpodRow(title: "Now Playing", action: IpodNowPlayingAction()),
      IpodRow(
        title: "Exit iPod Mode",
        action: IpodRun(() => FinampSetters.setInterfaceMode(InterfaceMode.modern.name)),
      ),
    ],
  );

  Future<List<IpodRow>> _playlistRows() async {
    final playlists = await _library.getItems(includeItemTypes: "Playlist");
    return playlists
        .map(
          (playlist) => IpodRow(
            title: playlist.name ?? "Unknown",
            subtitle: playlist.childCount == null ? null : "${playlist.childCount} songs",
            action: IpodPush(
              title: playlist.name ?? "Unknown",
              loader: () async => _songRows(await _library.getItems(parentItem: playlist)),
            ),
          ),
        )
        .toList();
  }

  Future<List<IpodRow>> _artistRows() async {
    final artists = await _library.getItems(includeItemTypes: "MusicArtist");
    return artists
        .map(
          (artist) => IpodRow(
            title: artist.name ?? "Unknown",
            action: IpodPush(
              title: artist.name ?? "Unknown",
              loader: () async => (await _library.getItems(parentItem: artist)).map(_albumRow).toList(),
            ),
          ),
        )
        .toList();
  }

  Future<List<IpodRow>> _albumRows() async {
    final albums = await _library.getItems(includeItemTypes: "MusicAlbum");
    return albums.map(_albumRow).toList();
  }

  IpodRow _albumRow(BaseItemDto album) => IpodRow(
    title: album.name ?? "Unknown",
    subtitle: album.albumArtist,
    action: IpodPush(
      title: album.name ?? "Unknown",
      loader: () async => _songRows(await _library.getItems(parentItem: album)),
    ),
  );

  Future<List<IpodRow>> _songMenuRows() async =>
      _songRows(await _library.getItems(includeItemTypes: "Audio", limit: 500));

  List<IpodRow> _songRows(List<BaseItemDto> songs) {
    return [
      for (final (index, song) in songs.indexed)
        IpodRow(
          title: song.name ?? "Unknown",
          subtitle: song.albumArtist,
          action: IpodPlay(tracks: songs, index: index),
        ),
    ];
  }

  Future<void> _shuffleAll() async {
    final songs = await _library.getItems(includeItemTypes: "Audio", limit: 200);
    if (songs.isEmpty) return;

    final shuffled = List.of(songs)..shuffle();
    await _play(shuffled, 0);
    openNowPlaying();
  }
}
