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

class CarPlayHelper {
  // logger?

  ConnectionStatusTypes connectionStatus = ConnectionStatusTypes.unknown;
  final FlutterCarplay _flutterCarplay = FlutterCarplay();

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
      FlutterCarplay.showSharedNowPlaying(animated: true);
    }
  }

  void setCarplayRootTemplate() { 
    FlutterCarplay.setRootTemplate(
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
              CPListSection(
                items: [
                  CPListItem(
                    text: "Albums", 
                    onPress: (complete, self) {
                      complete();
                    }),
                  CPListItem(text: "Artists"),
                  CPListItem(text: "Playlists"),
                  CPListItem(text: "Genres"),
                  CPListItem(text: "Tracks"),
                ]
              )
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

    _flutterCarplay.forceUpdateRootTemplate();
  }

  void show() { 
    GetIt.instance<MusicPlayerBackgroundTask>().skipToNext();
  }
}