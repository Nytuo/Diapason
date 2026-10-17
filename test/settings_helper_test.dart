import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce/hive.dart';

import 'support/test_env.dart';

class _NoUser extends Fake implements FinampUserHelper {
  @override
  FinampUser? get currentUser => null;
}

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    GetIt.instance.registerSingleton<FinampUserHelper>(_NoUser());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await env.dispose();
  });

  FinampSettings s() => FinampSettingsHelper.finampSettings;

  test('settings are read back from the box and can be overwritten as a whole', () {
    final changed = s()..shouldTranscode = !DefaultSettings.shouldTranscode;
    FinampSettingsHelper.overwriteFinampSettings(changed);
    expect(s().shouldTranscode, !DefaultSettings.shouldTranscode);
  });

  test('the settings provider listens to the box', () async {
    final listener = FinampSettingsHelper.finampSettingsListener;
    expect(listener.value.get('FinampSettings'), isNotNull);
    final seen = Hive.box<FinampSettings>('FinampSettings').watch().first;
    env.updateSettings((x) => x.volumeNormalizationActive = !DefaultSettings.volumeNormalizationActive);
    final event = await seen;
    expect((event.value as FinampSettings).volumeNormalizationActive, !DefaultSettings.volumeNormalizationActive);
  });

  test('download locations can be added and removed', () {
    final location = DownloadLocation(
      name: 'Phone',
      relativePath: null,
      id: 'loc1',
      baseDirectory: DownloadLocationType.internalDocuments,
    );
    FinampSettingsHelper.addDownloadLocation(location);
    expect(s().downloadLocationsMap.containsKey(location.id), isTrue);
    FinampSettingsHelper.deleteDownloadLocation(location.id);
    expect(s().downloadLocationsMap.containsKey(location.id), isFalse);
  });

  group('each reset puts its own settings back to the defaults', () {
    test('tabs', () {
      env.updateSettings((x) {
        x.tabOrder = [...DefaultSettings.tabOrder.reversed];
        x.showTabs = {for (final t in DefaultSettings.tabOrder) t: false};
      });
      FinampSettingsHelper.resetTabsSettings();
      expect(s().tabOrder, DefaultSettings.tabOrder);
      expect(s().showTabs.values, everyElement(isTrue));
    });

    test('customization, player screen, lyrics, album, artist, genre', () {
      env.updateSettings((x) {
        x.showStopButtonOnMediaNotification = !DefaultSettings.showStopButtonOnMediaNotification;
        x.oneLineMarqueeTextButton = !DefaultSettings.oneLineMarqueeTextButton;
        x.suppressPlayerPadding = !DefaultSettings.suppressPlayerPadding;
        x.hidePlayerBottomActions = !DefaultSettings.hidePlayerBottomActions;
        x.showLyricsTimestamps = !DefaultSettings.showLyricsTimestamps;
        x.lyricsFontSize = LyricsFontSize.large;
        x.showCoversOnAlbumScreen = !DefaultSettings.showCoversOnAlbumScreen;
        x.showArtistsTracksSection = !DefaultSettings.showArtistsTracksSection;
        x.genreFilterPlaylists = !DefaultSettings.genreFilterPlaylists;
      });
      FinampSettingsHelper.resetCustomizationSettings();
      FinampSettingsHelper.resetPlayerScreenSettings();
      FinampSettingsHelper.resetLyricsSettings();
      FinampSettingsHelper.resetAlbumSettings();
      FinampSettingsHelper.resetArtistSettings();
      FinampSettingsHelper.resetGenreSettings();
      expect(s().showStopButtonOnMediaNotification, DefaultSettings.showStopButtonOnMediaNotification);
      expect(s().oneLineMarqueeTextButton, DefaultSettings.oneLineMarqueeTextButton);
      expect(s().suppressPlayerPadding, DefaultSettings.suppressPlayerPadding);
      expect(s().hidePlayerBottomActions, DefaultSettings.hidePlayerBottomActions);
      expect(s().showLyricsTimestamps, DefaultSettings.showLyricsTimestamps);
      expect(s().lyricsFontSize, DefaultSettings.lyricsFontSize);
      expect(s().showCoversOnAlbumScreen, DefaultSettings.showCoversOnAlbumScreen);
      expect(s().showArtistsTracksSection, DefaultSettings.showArtistsTracksSection);
      expect(s().genreFilterPlaylists, DefaultSettings.genreFilterPlaylists);
    });

    test('visualizer', () {
      env.updateSettings((x) {
        x.visualizerEnabled = !DefaultSettings.visualizerEnabled;
        x.visualizerBins = DefaultSettings.visualizerBins + 8;
        x.visualizerFps = DefaultSettings.visualizerFps + 5;
        x.visualizerLogScale = !DefaultSettings.visualizerLogScale;
      });
      FinampSettingsHelper.resetVisualizerSettings();
      expect(s().visualizerEnabled, DefaultSettings.visualizerEnabled);
      expect(s().visualizerBins, DefaultSettings.visualizerBins);
      expect(s().visualizerFps, DefaultSettings.visualizerFps);
      expect(s().visualizerLogScale, DefaultSettings.visualizerLogScale);
    });

    test('layout (theme, grid, home screen)', () {
      env.updateSettings((x) {
        x.themeMode = ThemeMode.dark;
        x.amoledTheme = !DefaultSettings.amoledTheme;
        x.gridImageSize = DefaultSettings.gridImageSize + 20;
        x.showTextOnGridView = !DefaultSettings.showTextOnGridView;
        x.useMonochromeIcon = !DefaultSettings.useMonochromeIcon;
      });
      FinampSettingsHelper.resetLayoutSettings();
      FinampSettingsHelper.resetHomeScreenSettings();
      expect(s().themeMode, DefaultSettings.themeMode);
      expect(s().amoledTheme, DefaultSettings.amoledTheme);
      expect(s().gridImageSize, DefaultSettings.gridImageSize);
      expect(s().showTextOnGridView, DefaultSettings.showTextOnGridView);
      expect(s().useMonochromeIcon, DefaultSettings.useMonochromeIcon);
    });

    test('transcoding and downloads', () {
      env.updateSettings((x) {
        x.shouldTranscode = !DefaultSettings.shouldTranscode;
        x.transcodeBitrate = 64000;
        x.requireWifiForDownloads = !DefaultSettings.requireWifiForDownloads;
        x.downloadWorkers = DefaultSettings.downloadWorkers + 2;
        x.resyncOnStartup = !DefaultSettings.resyncOnStartup;
      });
      FinampSettingsHelper.resetTranscodingSettings();
      FinampSettingsHelper.resetDownloadSettings();
      expect(s().shouldTranscode, DefaultSettings.shouldTranscode);
      expect(s().transcodeBitrate, DefaultSettings.transcodeBitrate);
      expect(s().requireWifiForDownloads, DefaultSettings.requireWifiForDownloads);
      expect(s().downloadWorkers, DefaultSettings.downloadWorkers);
      expect(s().resyncOnStartup, DefaultSettings.resyncOnStartup);
    });

    test('audio service, playback reporting, normalization, interactions', () {
      env.updateSettings((x) {
        x.bufferSizeMegabytes = DefaultSettings.bufferSizeMegabytes + 10;
        x.audioFadeInDuration = const Duration(seconds: 9);
        x.enablePlayon = !DefaultSettings.enablePlayon;
        x.rpcEnabled = !DefaultSettings.rpcEnabled;
        x.volumeNormalizationActive = !DefaultSettings.volumeNormalizationActive;
        x.startInstantMixForIndividualTracks = !DefaultSettings.startInstantMixForIndividualTracks;
        x.showFastScroller = !DefaultSettings.showFastScroller;
      });
      FinampSettingsHelper.resetAudioServiceSettings();
      FinampSettingsHelper.resetPlaybackReportingSettings();
      FinampSettingsHelper.resetNormalizationSettings();
      FinampSettingsHelper.resetInteractionsSettings();
      expect(s().bufferSizeMegabytes, DefaultSettings.bufferSizeMegabytes);
      expect(s().audioFadeInDuration, DefaultSettings.audioFadeInDuration);
      expect(s().enablePlayon, DefaultSettings.enablePlayon);
      expect(s().rpcEnabled, DefaultSettings.rpcEnabled);
      expect(s().volumeNormalizationActive, DefaultSettings.volumeNormalizationActive);
      expect(s().startInstantMixForIndividualTracks, DefaultSettings.startInstantMixForIndividualTracks);
      expect(s().showFastScroller, DefaultSettings.showFastScroller);
    });

    test('network (no signed-in user is fine), accessibility and language', () {
      env.updateSettings((x) {
        x.autoOffline = AutoOfflineOption.network;
        x.useHighContrastColors = !DefaultSettings.useHighContrastColors;
        x.disableGesture = !DefaultSettings.disableGesture;
        x.locale = const Locale('fr');
      });
      FinampSettingsHelper.resetNetworkSettings();
      FinampSettingsHelper.resetAccessibilitySettings();
      FinampSettingsHelper.resetLocale();
      expect(s().autoOffline, DefaultSettings.autoOffline);
      expect(s().useHighContrastColors, DefaultSettings.useHighContrastColors);
      expect(s().disableGesture, DefaultSettings.disableGesture);
      expect(s().locale, DefaultSettings.locale);
    });
  });

  test('"reset everything" restores all of it at once', () {
    env.updateSettings((x) {
      x.shouldTranscode = !DefaultSettings.shouldTranscode;
      x.showFastScroller = !DefaultSettings.showFastScroller;
      x.lyricsFontSize = LyricsFontSize.large;
      x.themeMode = ThemeMode.light;
    });
    FinampSettingsHelper.resetAllSettings();
    expect(s().shouldTranscode, DefaultSettings.shouldTranscode);
    expect(s().showFastScroller, DefaultSettings.showFastScroller);
    expect(s().lyricsFontSize, DefaultSettings.lyricsFontSize);
    expect(s().themeMode, DefaultSettings.themeMode);
  });
}
