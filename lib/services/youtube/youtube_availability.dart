import 'dart:async';

import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

enum YouTubeSource { none, local, uploader }

class YouTubeStatus {
  const YouTubeStatus({
    this.source = YouTubeSource.none,
    this.localReady = false,
    this.uploader = UploaderCapabilities.none,
    this.uploaderWanted = false,
  });

  final YouTubeSource source;
  final bool localReady;
  final UploaderCapabilities uploader;

  final bool uploaderWanted;

  bool get available => source != YouTubeSource.none;

  List<String> get problems {
    if (available) return const [];
    final out = <String>[];
    if (LocalYtDlpService.supported) {
      out.add("yt-dlp isn't set up on this computer.");
    }
    if (uploaderWanted) {
      if (!uploader.reachable) {
        out.add(uploader.problem ?? "The uploader can't be reached.");
      } else if (!uploader.ytdlp) {
        out.add("Your uploader is connected, but its YouTube feature is off (DIAPASON_YTDLP_ENABLED=true).");
      }
    } else if (!LocalYtDlpService.supported) {
      out.add("Connect a diapason-uploader with YouTube support in Settings → Uploader.");
    }
    return out;
  }
}

class YouTubeAvailability with WidgetsBindingObserver {
  static final _log = Logger("YouTubeAvailability");

  final ValueNotifier<YouTubeStatus> status = ValueNotifier(const YouTubeStatus());
  Timer? _timer;
  bool _started = false;

  UploaderClient get _uploader => GetIt.instance<UploaderClient>();
  LocalYtDlpService get _local => GetIt.instance<LocalYtDlpService>();

  YouTubeSource get source => status.value.source;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _local.status.addListener(refresh);
    _local.config.addListener(refresh);
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => refresh());
    await refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  bool _refreshing = false;
  bool _again = false;

  Future<void> refresh() async {
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        await _probe();
      } while (_again);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _probe() async {
    final settings = FinampSettingsHelper.finampSettings;
    final localReady = LocalYtDlpService.supported && _local.status.value.isReady;
    final wantUploader = settings.uploaderYtProxy && _uploader.isConfigured;

    var caps = UploaderCapabilities.none;
    if (wantUploader) {
      caps = await _uploader.capabilities();
    }
    final uploaderOk = wantUploader && caps.reachable && caps.ytdlp;

    final preferUploader = _local.config.value.preferUploader;
    final source = switch ((localReady, uploaderOk)) {
      (true, true) => preferUploader ? YouTubeSource.uploader : YouTubeSource.local,
      (true, false) => YouTubeSource.local,
      (false, true) => YouTubeSource.uploader,
      _ => YouTubeSource.none,
    };

    final next = YouTubeStatus(source: source, localReady: localReady, uploader: caps, uploaderWanted: wantUploader);
    final previous = status.value;
    if (previous.source != next.source || previous.uploader.state != next.uploader.state) {
      _log.info(
        "YouTube source: ${previous.source.name} -> ${next.source.name} "
        "(local=${next.localReady}, uploader=${caps.state.name}, uploaderYtdlp=${caps.ytdlp})",
      );
    }
    status.value = next;
  }

  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

class YouTubeStatusNotifier extends Notifier<YouTubeStatus> {
  @override
  YouTubeStatus build() {
    final availability = GetIt.instance<YouTubeAvailability>();
    void sync() => state = availability.status.value;
    availability.status.addListener(sync);
    ref.onDispose(() => availability.status.removeListener(sync));
    return availability.status.value;
  }
}

final youTubeStatusProvider = NotifierProvider<YouTubeStatusNotifier, YouTubeStatus>(YouTubeStatusNotifier.new);

final youTubeAvailableProvider = Provider<bool>((ref) => ref.watch(youTubeStatusProvider).available);

bool get isYouTubeAvailable => GetIt.instance<YouTubeAvailability>().status.value.available;
