import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/tvos/appletv_audio_channel.dart';
import 'package:get_it/get_it.dart';

/// The playing position, ticking while audio plays. Same as `AudioService.position`, except on tvOS, where
/// audio_service has no native side and its static handler is never set up (the handler is built directly), so
/// `AudioService.position` would throw; there the position is worked out from the handler's playback state.
Stream<Duration> get audioPosition => AppleTvAudioChannel.isSupported ? _tvPosition : AudioService.position;

/// One shared stream, so widgets rebuilding do not resubscribe (which would restart the ticking and make bars stutter).
/// It ticks about 30 times a second so progress bars move smoothly instead of in jumps.
final Stream<Duration> _tvPosition = () {
  final handler = GetIt.instance<MusicPlayerBackgroundTask>();
  var last = Duration.zero;
  return Stream<Duration>.periodic(const Duration(milliseconds: 33), (_) {
    final live = handler.tvLivePosition;
    // The native player's reports land a little behind the clock; never step back for that, only for a real seek.
    if (live < last && last - live < const Duration(seconds: 1)) return last;
    return last = live;
  }).asBroadcastStream();
}();
