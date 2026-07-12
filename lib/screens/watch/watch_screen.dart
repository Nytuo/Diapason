import 'package:audio_service/audio_service.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class WatchScreen extends StatelessWidget {
  const WatchScreen({super.key});

  static const routeName = "/watch";

  MusicPlayerBackgroundTask get _player => GetIt.instance<MusicPlayerBackgroundTask>();
  QueueService get _queue => GetIt.instance<QueueService>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: FractionallySizedBox(
            widthFactor: 0.7,
            heightFactor: 0.7,
            child: StreamBuilder<FinampQueueInfo?>(
              stream: _queue.getQueueStream(),
              builder: (context, snapshot) {
                final track = snapshot.data?.currentTrack?.baseItem;

                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      track?.name ?? "Nothing playing",
                      style: const TextStyle(color: Colors.white, fontSize: 14.0, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (track != null) ...[
                      const SizedBox(height: 2.0),
                      Text(
                        track.albumArtist ?? "",
                        style: const TextStyle(color: Colors.white54, fontSize: 11.0),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],

                    const SizedBox(height: 8.0),
                    StreamBuilder<PlaybackState>(
                      stream: _player.playbackState,
                      builder: (context, snapshot) {
                        final playing = snapshot.data?.playing ?? false;
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              iconSize: 22.0,
                              color: Colors.white,
                              icon: const Icon(TablerIcons.player_skip_back),
                              onPressed: _player.skipToPrevious,
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              iconSize: 36.0,
                              color: Colors.white,
                              icon: Icon(playing ? TablerIcons.player_pause : TablerIcons.player_play),
                              onPressed: playing ? _player.pause : _player.play,
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              iconSize: 22.0,
                              color: Colors.white,
                              icon: const Icon(TablerIcons.player_skip_forward),
                              onPressed: _player.skipToNext,
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
