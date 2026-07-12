import 'dart:convert';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/scrobbling/lastfm_client.dart';
import 'package:diapason/services/scrobbling/listenbrainz_client.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScrobbleService {
  ScrobbleService({LastFmClient? lastFm, ListenBrainzClient? listenBrainz})
    : _listenBrainz = listenBrainz ?? ListenBrainzClient(),
      _lastFmOverride = lastFm;

  static final _log = Logger("ScrobbleService");
  static const _pendingKey = "diapason.pending_scrobbles";

  static const _minimumPlayFraction = 0.5;
  static const _minimumPlayDuration = Duration(minutes: 4);

  final ListenBrainzClient _listenBrainz;
  final LastFmClient? _lastFmOverride;

  LastFmClient get _lastFm =>
      _lastFmOverride ??
      LastFmClient(
        apiKey: FinampSettingsHelper.finampSettings.lastFmApiKey,
        apiSecret: FinampSettingsHelper.finampSettings.lastFmApiSecret,
      );

  String get _listenBrainzToken => FinampSettingsHelper.finampSettings.listenBrainzToken;
  String get _lastFmSession => FinampSettingsHelper.finampSettings.lastFmSessionKey;

  bool get listenBrainzEnabled => _listenBrainzToken.isNotEmpty;
  bool get lastFmEnabled => _lastFmSession.isNotEmpty && _lastFm.isConfigured;
  bool get anyEnabled => listenBrainzEnabled || lastFmEnabled;

  static bool qualifies(Duration played, Duration? total) {
    if (played >= _minimumPlayDuration) return true;
    if (total == null || total == Duration.zero) return false;
    return played.inMilliseconds >= total.inMilliseconds * _minimumPlayFraction;
  }

  Future<void> nowPlaying(BaseItemDto item) async {
    if (!anyEnabled) return;
    if (listenBrainzEnabled) await _listenBrainz.submitPlayingNow(item, _listenBrainzToken);
    if (lastFmEnabled) await _lastFm.updateNowPlaying(item, _lastFmSession);
  }

  Future<void> scrobble(BaseItemDto item, {required Duration played, DateTime? startedAt}) async {
    if (!anyEnabled) return;
    if (!qualifies(played, item.runTimeTicksDuration())) {
      _log.fine("'${item.name}' played ${played.inSeconds}s — too short to scrobble");
      return;
    }

    final started = startedAt ?? DateTime.now().subtract(played);
    await _send(item, started);
    await retryPending();
  }

  Future<void> _send(BaseItemDto item, DateTime startedAt) async {
    var delivered = true;
    if (listenBrainzEnabled) {
      delivered &= await _listenBrainz.submitListen(item, _listenBrainzToken, startedAt: startedAt);
    }
    if (lastFmEnabled) {
      delivered &= await _lastFm.scrobble(item, _lastFmSession, startedAt: startedAt);
    }
    if (!delivered) {
      _log.info("Parking a scrobble for '${item.name}' to retry later");
      await _park(item, startedAt);
    }
  }

  Future<void> retryPending() async {
    final pending = await _pending();
    if (pending.isEmpty) return;

    final stillFailing = <Map<String, dynamic>>[];
    for (final entry in pending) {
      final item = BaseItemDto.fromJson(entry["item"] as Map<String, dynamic>);
      final startedAt = DateTime.fromMillisecondsSinceEpoch(entry["startedAt"] as int);

      var delivered = true;
      if (listenBrainzEnabled) {
        delivered &= await _listenBrainz.submitListen(item, _listenBrainzToken, startedAt: startedAt);
      }
      if (lastFmEnabled) {
        delivered &= await _lastFm.scrobble(item, _lastFmSession, startedAt: startedAt);
      }
      if (!delivered) stillFailing.add(entry);
    }

    await _savePending(stillFailing);
    _log.info("Retried ${pending.length} parked scrobble(s); ${stillFailing.length} still failing");
  }

  Future<int> pendingCount() async => (await _pending()).length;

  Future<void> _park(BaseItemDto item, DateTime startedAt) async {
    final pending = await _pending();
    pending.add({"item": item.toJson(), "startedAt": startedAt.millisecondsSinceEpoch});
    await _savePending(pending.length > 500 ? pending.sublist(pending.length - 500) : pending);
  }

  Future<List<Map<String, dynamic>>> _pending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (e) {
      _log.warning("Could not read parked scrobbles, dropping them: $e");
      return [];
    }
  }

  Future<void> _savePending(List<Map<String, dynamic>> pending) async {
    final prefs = await SharedPreferences.getInstance();
    if (pending.isEmpty) {
      await prefs.remove(_pendingKey);
    } else {
      await prefs.setString(_pendingKey, jsonEncode(pending));
    }
  }
}
