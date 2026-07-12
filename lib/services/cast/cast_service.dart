import 'dart:io';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:flutter_chrome_cast/cast_context.dart';
import 'package:flutter_chrome_cast/discovery.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_chrome_cast/enums.dart';
import 'package:flutter_chrome_cast/media.dart';
import 'package:flutter_chrome_cast/models.dart';
import 'package:flutter_chrome_cast/session.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

class CastService {
  CastService();

  static final _log = Logger("CastService");

  bool _initialised = false;

  Future<void> initialise() async {
    if (_initialised) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
      final options = Platform.isIOS
          ? IOSGoogleCastOptions(
              GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(appId),
              stopCastingOnAppTerminated: true,
            )
          : GoogleCastOptionsAndroid(appId: appId, stopCastingOnAppTerminated: true);

      await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
      _initialised = true;
      _log.info("Google Cast is ready");
    } catch (e) {
      _log.warning("Could not initialise Google Cast: $e");
    }
  }

  Stream<List<GoogleCastDevice>> get devices => GoogleCastDiscoveryManager.instance.devicesStream;

  Stream<GoogleCastSession?> get session => GoogleCastSessionManager.instance.currentSessionStream;

  bool get isCasting => GoogleCastSessionManager.instance.currentSession != null;

  Future<void> startDiscovery() async {
    await initialise();
    if (!_initialised) return;
    GoogleCastDiscoveryManager.instance.startDiscovery();
  }

  void stopDiscovery() {
    if (!_initialised) return;
    GoogleCastDiscoveryManager.instance.stopDiscovery();
  }

  Future<void> connect(GoogleCastDevice device) =>
      GoogleCastSessionManager.instance.startSessionWithDevice(device);

  Future<void> disconnect() => GoogleCastSessionManager.instance.endSessionAndStopCasting();

  Future<bool> canCast(BaseItemDto item) async {
    try {
      final source = await GetIt.instance<AggregateBackend>().resolveStream(item, transcode: false);
      return !source.isLocalFile;
    } catch (e) {
      return false;
    }
  }

  Future<bool> cast(BaseItemDto item) async {
    if (!isCasting) return false;

    try {
      final source = await GetIt.instance<AggregateBackend>().resolveStream(item, transcode: false);
      if (source.isLocalFile) {
        _log.warning("'${item.name}' is a local file; a Cast device cannot reach it");
        return false;
      }

      await GoogleCastRemoteMediaClient.instance.loadMedia(
        GoogleCastMediaInformation(
          contentId: item.id.raw,
          contentUrl: source.uri,
          streamType: CastMediaStreamType.buffered,
          contentType: "audio/*",
          duration: item.runTimeTicksDuration(),
          metadata: GoogleCastMusicMediaMetadata(
            title: item.name,
            artist: item.albumArtist ?? item.artists?.firstOrNull,
            albumName: item.album,
          ),
        ),
        autoPlay: true,
      );
      _log.info("Casting '${item.name}'");
      return true;
    } catch (e) {
      _log.warning("Could not cast '${item.name}': $e");
      return false;
    }
  }

  Future<void> play() => GoogleCastRemoteMediaClient.instance.play();
  Future<void> pause() => GoogleCastRemoteMediaClient.instance.pause();
  Future<void> stop() => GoogleCastRemoteMediaClient.instance.stop();

  Future<void> seek(Duration position) => GoogleCastRemoteMediaClient.instance.seek(
    GoogleCastMediaSeekOption(position: position),
  );

}
