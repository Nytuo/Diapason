import 'dart:async';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/audio_position.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Asks the uploader to download the next YouTube track(s) shortly before the current one ends, so they start
/// without a wait. The uploader has to download a track completely before it can serve it.
///
/// Normal queues prepare one track, once the current one is [_fraction] played. A YouTube radio / discover queue
/// prepares the next [_radioAhead] tracks at that point.
class YouTubePrefetcher {
  static final _log = Logger("YouTubePrefetcher");

  static const _fraction = 0.75;
  static const _radioAhead = 2;

  StreamSubscription<Duration>? _sub;
  String? _firedFor; // queue item the prefetch already ran for
  final _asked = <String>{}; // video ids already requested, so seeking around doesn't repeat requests

  void start() {
    _sub ??= audioPosition.listen(_onPosition);
  }

  void dispose() => _sub?.cancel();

  bool _isRadio(FinampQueueInfo info) {
    final settings = FinampSettingsHelper.finampSettings;
    if (settings.radioEnabled || settings.autoRadioEnabled) return true;
    return info.source.name.pretranslatedName?.startsWith("YouTube Discover") ?? false;
  }

  void _onPosition(Duration position) {
    final youtube = GetIt.instance<YouTubeService>();
    if (!youtube.usesProxy) return;
    final info = GetIt.instance<QueueService>().getQueueStream().valueOrNull;
    final current = info?.currentTrack;
    if (info == null || current == null || current.id == _firedFor) return;

    final total = current.item.duration;
    if (total == null || total.inMilliseconds <= 0) return;
    if (position.inMilliseconds < total.inMilliseconds * _fraction) return;
    _firedFor = current.id;

    final upcoming = [...info.nextUp, ...info.queue]
        .where((t) => t.baseItemId.sourceId == YouTubeService.sourceId)
        .take(_isRadio(info) ? _radioAhead : 1);
    final uploader = GetIt.instance<UploaderClient>();
    for (final track in upcoming) {
      final id = track.baseItemId.nativeId;
      if (!_asked.add(id)) continue;
      _log.fine("Preparing '${track.item.title}' on the uploader");
      unawaited(uploader.precacheStream(id));
    }
  }
}
