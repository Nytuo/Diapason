import 'dart:convert';
import 'dart:ffi';

import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:finamp/components/MusicScreen/music_screen_tab_view.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import 'audio_service_helper.dart';
import 'finamp_settings_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';
import 'queue_service.dart';
import 'android_auto_helper.dart';

class CarPlayHelper {
  // logger?

  ConnectionStatusTypes connectionStatus = ConnectionStatusTypes.unknown;
  final FlutterCarplay _flutterCarplay = FlutterCarplay();

  final _androidAutoHelper = GetIt.instance<AndroidAutoHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _downloadsService = GetIt.instance<DownloadsService>();

  void setupCarplay() { 
    _flutterCarplay.addListenerOnConnectionChange(onConnectionChange);
    setCarplayRootTemplate();
  }

  void disposeCarplay() { 
    _flutterCarplay.removeListenerOnConnectionChange();
  }

  void onConnectionChange(ConnectionStatusTypes status) {
    if (status == ConnectionStatusTypes.connected) {
    }
  }

  Future<List<BaseItemDto>> getTabItems (TabContentType tabContentType) async { 
    // limit amount so it doesn't crash / take forever on large libraries 
    const onlineModeLimit = 250;
    const offlineModeLimit = 1000;

    final sortBy = FinampSettingsHelper.finampSettings.getTabSortBy(tabContentType);
    final sortOrder = FinampSettingsHelper.finampSettings.getSortOrder(tabContentType);
    
    
    
    // Check for offline version first 

    // Fetch the online version if we an't get the offline version 
    
    final items = await _jellyfinApiHelper.getItems(
      parentItem: tabContentType.itemType == BaseItemDtoType.playlist ? null : _finampUserHelper.currentUser?.currentView,
      includeItemTypes: tabContentType.itemType.idString, 
      sortBy: 
          sortBy?.jellyfinName(tabContentType) ?? 
          (tabContentType == TabContentType.tracks ? "Album,Sortname" : "Sortname"),
      sortOrder: tabContentType == TabContentType.tracks ? null : sortOrder.toString(),
      limit: onlineModeLimit,
    );
    return items ?? [];
  }

  // CarPlay Control

  Future<void> setCarplayRootTemplate() async { 
    List<MediaItem> rootItems = await GetIt.instance<MusicPlayerBackgroundTask>().getChildren(AudioService.browsableRootId);
    CPListSection librarySection = CPListSection(
      items: []);

    for (final item in rootItems) {
      librarySection.items.add(CPListItem(
        text: item.title,
        onPress: (complete, self) {
          final parentId = MediaItemId.fromJson(jsonDecode(item.id) as Map<String, dynamic>);

          switch(parentId.contentType) {
            case TabContentType.albums: showAlbumsTemplate(parentId);
            case TabContentType.artists: showArtistsTemplate(item);
            case TabContentType.playlists:
            case TabContentType.genres:
            case TabContentType.tracks: 
          }
          complete();
        }
      ));
    } 

    await FlutterCarplay.setRootTemplate(
      rootTemplate: CPTabBarTemplate(
        templates: [
          CPListTemplate(
            sections: [],
            title: 'Home',
            emptyViewTitleVariants: ['Home'],
            emptyViewSubtitleVariants: [
              'Home not yet implemented.'
            ],
            systemIcon: 'music.note.house',
          ),
          CPListTemplate(
            sections: [],
            title: 'Recent',
            emptyViewTitleVariants: ['Recent'],
            emptyViewSubtitleVariants: [
              'Recent not yet implemented.'
            ],
            systemIcon: 'clock',
          ),
          CPListTemplate(
            sections: [],
            title: 'Search',
            emptyViewTitleVariants: ['Search'],
            emptyViewSubtitleVariants: [
              'Search not yet implemented.'
            ],
            systemIcon: 'magnifyingglass',
          ),
          CPListTemplate(
            sections: [
              // CPListSection(
              //   items: [
              //     CPListItem(
              //       text: "Albums", 
              //       onPress: (complete, self) {
              //         complete();
              //       }),
              //     CPListItem(text: "Artists"),
              //     CPListItem(text: "Playlists"),
              //     CPListItem(text: "Genres"),
              //     CPListItem(text: "Tracks"),
              //   ]
              // ),
            librarySection
            ],
            title: 'Library',
            emptyViewTitleVariants: ['Library'],
            emptyViewSubtitleVariants: [
              'Library not yet implemented.'
            ],
            systemIcon: 'play.square.stack',
          ),
        ],
      ),
    );

    await _flutterCarplay.forceUpdateRootTemplate();
  }

  Future<void> showPlaylistTemplate(MediaItemId parent) async { 
    // List<MediaItem> mediaItems = await GetIt.instance<MusicPlayerBackgroundTask>().getChildren(parent.id);
    List<MediaItem> mediaItems = await _androidAutoHelper.getMediaItems(parent);

    CPListSection playlistSection = CPListSection(items: []);

    // Add shuffle play to top 
    playlistSection.items.add(CPListItem(
      text: "Shuffle Play", 
      onPress: (complete, self) async { 
        await _androidAutoHelper.playFromMediaId(parent, order: FinampPlaybackOrder.shuffled);
        complete();
      },
    ));

    mediaItems.asMap().forEach((index, item) { 
      final itemId = MediaItemId.fromJson(jsonDecode(item.id) as Map<String, dynamic>);

      playlistSection.items.add(CPListItem(
        text: item.title,
        detailText: item.artist,
        onPress: (complete, self) async {
          await _androidAutoHelper.playFromMediaId(parent, index: index);
          complete();
        },
        ));
    });

    CPListTemplate playlistTemplate = CPListTemplate(
      sections: [
        playlistSection,
      ], 
      systemIcon: 'gear');
  
    await FlutterCarplay.push(template: playlistTemplate);
  }

  Future<void> showAlbumsTemplate(MediaItemId parent) async { 
    // Fetch child items of root navigation 
    List<BaseItemDto> mediaItems = await getTabItems(TabContentType.albums);
    // List<MediaItem> childItems = await _androidAutoHelper.getMediaItems(parentId);
  
    CPListSection albumsSection = CPListSection(items: []);

    for (final item in mediaItems) { 
      albumsSection.items.add(CPListItem(
        text: item.name ?? "Unknown Name", // Todo localization
        detailText: "Artist TBD", // TODO generate subtitle
        onPress: (complete, self) async {
          // await showPlaylistTemplate(itemId);
          complete();
        }
        ));
    }

    CPListTemplate albumsTemplate = CPListTemplate(
      sections: [
        albumsSection,
      ], 
      systemIcon: 'gear');
  
    await FlutterCarplay.push(template: albumsTemplate);
  }

  Future<void> showArtistsTemplate(MediaItem parent) async { 
    // Fetch child items of this type 
    List<BaseItemDto> mediaItems = await getTabItems(TabContentType.artists);

    CPListSection artistsSection = CPListSection(items: []);

    for (final item in mediaItems) { 

      artistsSection.items.add(CPListItem(
        text: item.name ?? "Unknown Name", // TODO localization for this
        // detailText: item.albumArtists.toString(),
        onPress: (complete, self) async {
          // await showPlaylistTemplate(itemId);
          complete();
        }
        ));
    }

    CPListTemplate albumsTemplate = CPListTemplate(
      sections: [
        artistsSection,
      ], 
      systemIcon: 'gear');
  
    await FlutterCarplay.push(template: albumsTemplate);
  }
}