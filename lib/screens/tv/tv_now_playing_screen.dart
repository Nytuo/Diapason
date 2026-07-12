import 'package:audio_service/audio_service.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class TvNowPlayingScreen extends StatelessWidget {
  const TvNowPlayingScreen({super.key});

  static const routeName = "/tv/now-playing";

  MusicPlayerBackgroundTask get _player => GetIt.instance<MusicPlayerBackgroundTask>();
  QueueService get _queue => GetIt.instance<QueueService>();

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.mediaPlayPause:
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        _player.playbackState.valueOrNull?.playing ?? false ? _player.pause() : _player.play();
      case LogicalKeyboardKey.mediaTrackNext:
      case LogicalKeyboardKey.arrowRight:
        _player.skipToNext();
      case LogicalKeyboardKey.mediaTrackPrevious:
      case LogicalKeyboardKey.arrowLeft:
        _player.skipToPrevious();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) => _handleKey(event),
        child: StreamBuilder<FinampQueueInfo?>(
          stream: _queue.getQueueStream(),
          builder: (context, snapshot) {
            final track = snapshot.data?.currentTrack?.baseItem;

            return Center(
              child: Padding(
                padding: const EdgeInsets.all(64.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(TablerIcons.disc, size: 140.0, color: Colors.white24),
                    const SizedBox(height: 48.0),
                    Text(
                      track?.name ?? "Nothing playing",
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Colors.white),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12.0),
                    Text(
                      track?.albumArtist ?? "",
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white70),
                    ),

                    const SizedBox(height: 48.0),
                    StreamBuilder<PlaybackState>(
                      stream: _player.playbackState,
                      builder: (context, snapshot) {
                        final playing = snapshot.data?.playing ?? false;
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              iconSize: 48.0,
                              color: Colors.white,
                              icon: const Icon(TablerIcons.player_skip_back),
                              onPressed: _player.skipToPrevious,
                            ),
                            const SizedBox(width: 32.0),
                            IconButton(
                              iconSize: 72.0,
                              color: Colors.white,
                              icon: Icon(playing ? TablerIcons.player_pause : TablerIcons.player_play),
                              onPressed: playing ? _player.pause : _player.play,
                            ),
                            const SizedBox(width: 32.0),
                            IconButton(
                              iconSize: 48.0,
                              color: Colors.white,
                              icon: const Icon(TablerIcons.player_skip_forward),
                              onPressed: _player.skipToNext,
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
