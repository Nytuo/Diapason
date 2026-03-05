import 'dart:io';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/now_playing_bar.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import 'android_auto_helper.dart';
import 'audio_service_helper.dart';
import 'downloads_service.dart';
import 'finamp_settings_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';
import 'queue_service.dart';

/// iOS-specific helpers for playback state sync and Siri media intents.

final _logger = Logger('IosHelpers');

/// Syncs playback state to iOS's MPNowPlayingInfoCenter.
///
/// TODO: This is a workaround because audio_service doesn't set
/// MPNowPlayingInfoCenter.playbackState on iOS (only on macOS).
/// This causes CarPlay's Now Playing screen to not reflect the correct
/// play/pause state when playback is started from the phone.
/// Consider contributing a fix upstream to audio_service.
class IosPlaybackStateSync {
  static const _channel = MethodChannel('com.unicornsonlsd.finamp/playback_state');

  /// Sets the playback state on iOS's MPNowPlayingInfoCenter.
  /// This is needed for CarPlay to show the correct play/pause state.
  static Future<void> setPlaybackState({required bool isPlaying}) async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod('setPlaybackState', {'isPlaying': isPlaying});
      _logger.fine('Set iOS playback state to ${isPlaying ? "playing" : "paused"}');
    } catch (e) {
      _logger.warning('Failed to set iOS playback state: $e');
    }
  }
}

/// Handles Siri media intent commands from iOS.
///
/// This enables voice commands like "Hey Siri, play [song/artist] on Finamp"
/// from anywhere on iOS (phone, CarPlay, AirPods, etc.).
class IosSiriHandler {
  static const _siriIntentChannel = MethodChannel('com.unicornsonlsd.finamp/siri_intent');

  /// Sets up the method channel handler for Siri media intents.
  /// Should be called once during app initialization.
  static void setup() {
    if (!Platform.isIOS) return;

    _siriIntentChannel.setMethodCallHandler((call) async {
      _logger.info("Received Siri intent: ${call.method}");

      switch (call.method) {
        case 'playFromSearch':
          await _handlePlayFromSearch(call.arguments as Map<dynamic, dynamic>?);
          break;
        case 'searchMedia':
          await _handleSearchMedia(call.arguments as Map<dynamic, dynamic>?);
          break;
        default:
          _logger.warning("Unknown Siri intent method: ${call.method}");
      }
    });

    _logger.info("Siri intent handler set up");
  }

  /// Handles Siri "Play X on Finamp" voice commands.
  ///
  /// Siri typically only populates `mediaName` (mapped to `query`) for ~80% of
  /// requests. `artistName`/`albumName` are only set for compound queries like
  /// "Play X by Y". So we must search across entity types ourselves.
  static Future<void> _handlePlayFromSearch(Map<dynamic, dynamic>? arguments) async {
    if (arguments == null) {
      _logger.warning("Siri playFromSearch called with null arguments");
      return;
    }

    final query = arguments['query'] as String?;
    final artist = arguments['artist'] as String?;
    final album = arguments['album'] as String?;
    final genre = arguments['genre'] as String?;
    final shuffle = arguments['shuffle'] as bool? ?? false;
    final mediaType = arguments['mediaType'] as String?;

    _logger.info("Siri playFromSearch - query: $query, artist: $artist, album: $album, genre: $genre, mediaType: $mediaType, shuffle: $shuffle");

    if (shuffle) {
      if (query == null && artist == null && album == null) {
        await _shuffleAll();
        _showPlayerScreen();
        return;
      }
    }

    // If Siri provided explicit artist/album fields (compound query like "Play X by Y"),
    // delegate to Android Auto's search logic which handles extras correctly
    if (artist != null || album != null) {
      final Map<String, dynamic> extras = {};
      if (artist != null) extras['android.intent.extra.artist'] = artist;
      if (album != null) extras['android.intent.extra.album'] = album;
      if (query != null) extras['android.intent.extra.title'] = query;

      final androidAutoHelper = GetIt.instance<AndroidAutoHelper>();
      await androidAutoHelper.playFromSearch(AndroidAutoSearchQuery(
        query ?? artist ?? album ?? '',
        extras,
      ));
      _showPlayerScreen();
      return;
    }

    // For bare queries (most Siri requests), do a smart multi-type search
    final searchTerm = query ?? genre ?? '';
    if (searchTerm.isEmpty) {
      // No query at all - shuffle everything
      await _shuffleAll();
      _showPlayerScreen();
      return;
    }

    final played = await _smartSearch(searchTerm, mediaType);
    if (!played) {
      // Fall back to Android Auto's generic search (playlists + tracks)
      _logger.info("Smart search found nothing, falling back to generic search");
      final androidAutoHelper = GetIt.instance<AndroidAutoHelper>();
      await androidAutoHelper.playFromSearch(AndroidAutoSearchQuery(searchTerm, null));
    }
    _showPlayerScreen();
  }

  /// Searches for the query across entity types and starts playback if found.
  /// Returns true if something was played.
  static Future<bool> _smartSearch(String searchTerm, String? mediaType) async {
    final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
    final audioServiceHelper = GetIt.instance<AudioServiceHelper>();
    final queueService = GetIt.instance<QueueService>();

    // If Siri told us the type (e.g., "Play the artist Taylor Swift"), search that type directly
    if (mediaType == 'artist') {
      return await _searchAndPlayArtist(searchTerm, jellyfinApiHelper, audioServiceHelper);
    } else if (mediaType == 'album') {
      return await _searchAndPlayAlbum(searchTerm, jellyfinApiHelper, queueService);
    } else if (mediaType == 'song') {
      // For explicit song requests, let the Android Auto fallback handle it
      return false;
    }

    // No type hint - search in priority order: artists -> albums -> fallback to tracks
    _logger.info("Smart search: trying artists for '$searchTerm'");
    if (await _searchAndPlayArtist(searchTerm, jellyfinApiHelper, audioServiceHelper)) {
      return true;
    }

    _logger.info("Smart search: trying albums for '$searchTerm'");
    if (await _searchAndPlayAlbum(searchTerm, jellyfinApiHelper, queueService)) {
      return true;
    }

    return false;
  }

  static Future<bool> _searchAndPlayArtist(
    String searchTerm,
    JellyfinApiHelper jellyfinApiHelper,
    AudioServiceHelper audioServiceHelper,
  ) async {
    final artists = await jellyfinApiHelper.getArtists(searchTerm: searchTerm, limit: 5);
    if (artists == null || artists.isEmpty) return false;

    // Pick the best match (prefer exact match, then first result)
    final exactMatch = artists.where(
      (a) => a.name?.toLowerCase() == searchTerm.toLowerCase(),
    );
    final artist = exactMatch.isNotEmpty ? exactMatch.first : artists.first;

    _logger.info("Smart search: found artist '${artist.name}', starting mix");
    await audioServiceHelper.startInstantMixForArtists([artist]);
    return true;
  }

  static Future<bool> _searchAndPlayAlbum(
    String searchTerm,
    JellyfinApiHelper jellyfinApiHelper,
    QueueService queueService,
  ) async {
    final albums = await jellyfinApiHelper.getItems(
      searchTerm: searchTerm,
      includeItemTypes: "MusicAlbum",
      limit: 5,
    );
    if (albums == null || albums.isEmpty) return false;

    final exactMatch = albums.where(
      (a) => a.name?.toLowerCase() == searchTerm.toLowerCase(),
    );
    final selectedAlbum = exactMatch.isNotEmpty ? exactMatch.first : albums.first;

    // Fetch album tracks
    final tracks = await jellyfinApiHelper.getItems(
      parentItem: selectedAlbum,
      includeItemTypes: "Audio",
      sortBy: "ParentIndexNumber,IndexNumber,SortName",
      sortOrder: "Ascending",
      limit: 200,
    );
    if (tracks == null || tracks.isEmpty) return false;

    _logger.info("Smart search: found album '${selectedAlbum.name}' with ${tracks.length} tracks");
    await queueService.startPlayback(
      items: tracks,
      source: QueueItemSource(
        type: QueueItemSourceType.album,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: selectedAlbum.name,
        ),
        id: selectedAlbum.id,
        item: selectedAlbum,
      ),
      order: FinampPlaybackOrder.linear,
    );
    return true;
  }

  /// Shows the player screen in the Flutter app after Siri-initiated playback.
  static void _showPlayerScreen() {
    final context = GlobalSnackbar.materialAppNavigatorKey.currentContext;
    if (context != null && context.mounted) {
      NowPlayingBar.openPlayerScreen(context);
    }
  }

  static const _siriShuffleLimit = 30;

  /// Fast shuffle (same approach as CarPlay) - fetches 30 random tracks instead of 250.
  static Future<void> _shuffleAll() async {
    final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
    final finampUserHelper = GetIt.instance<FinampUserHelper>();
    final queueService = GetIt.instance<QueueService>();

    List<BaseItemDto>? items;

    if (FinampSettingsHelper.finampSettings.isOffline) {
      final downloadsService = GetIt.instance<DownloadsService>();
      items = (await downloadsService.getAllTracks(
        viewFilter: finampUserHelper.currentUser?.currentView?.id,
        nullableViewFilters: FinampSettingsHelper.finampSettings.showDownloadsWithUnknownLibrary,
      )).map((e) => e.baseItem!).toList();
      items.shuffle();
      if (items.length > _siriShuffleLimit) {
        items = items.sublist(0, _siriShuffleLimit);
      }
    } else {
      items = await jellyfinApiHelper.getItems(
        parentItem: finampUserHelper.currentUser?.currentView,
        includeItemTypes: "Audio",
        sortBy: "Random",
        limit: _siriShuffleLimit,
      );
    }

    if (items != null && items.isNotEmpty) {
      await queueService.startPlayback(
        items: items,
        source: QueueItemSource.rawId(
          type: QueueItemSourceType.allTracks,
          name: const QueueItemSourceName(
            type: QueueItemSourceNameType.shuffleAll,
          ),
          id: "shuffleAll",
        ),
        order: FinampPlaybackOrder.shuffled,
      );
    }
  }

  /// Handles Siri "Search for X on Finamp" voice commands
  static Future<void> _handleSearchMedia(Map<dynamic, dynamic>? arguments) async {
    if (arguments == null) {
      _logger.warning("Siri searchMedia called with null arguments");
      return;
    }

    final query = arguments['query'] as String?;
    _logger.info("Siri searchMedia - query: $query");

    // For now, just play the search result (same as playFromSearch)
    // In the future, this could navigate to a search results screen
    await _handlePlayFromSearch(arguments);
  }
}
