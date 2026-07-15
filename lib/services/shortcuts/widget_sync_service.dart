import 'dart:convert';
import 'dart:io';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/album_image_provider.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/shortcuts/shortcut_service.dart';
import 'package:diapason/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:home_widget/home_widget.dart';
import 'package:logging/logging.dart';

class WidgetSyncService {
  WidgetSyncService();

  static final _log = Logger("WidgetSyncService");

  static const _appGroupId = "group.fr.nytuo.diapason";
  static const _androidProvider = "DiapasonWidgetProvider";
  static const _iosWidgetName = "DiapasonWidget";

  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _started = true;

    try {
      await HomeWidget.setAppGroupId(_appGroupId);
    } catch (e) {
      _log.fine("Could not set the widget app group: $e");
    }

    GetIt.instance<QueueService>().getQueueStream().listen((_) => sync());
    GetIt.instance<ShortcutService>().addListener(sync);
    GetIt.instance<MusicPlayerBackgroundTask>().playbackState
        .map((state) => state.playing)
        .distinct()
        .listen((_) => sync());

    await sync();
  }

  Future<void> sync() async {
    if (!_started) return;

    try {
      final track = GetIt.instance<QueueService>().getQueue().currentTrack?.baseItem;
      final playing = GetIt.instance<MusicPlayerBackgroundTask>().playbackState.valueOrNull?.playing ?? false;

      await HomeWidget.saveWidgetData<String>("title", track?.name ?? "");
      await HomeWidget.saveWidgetData<String>("artist", track?.albumArtist ?? track?.artists?.firstOrNull ?? "");
      await HomeWidget.saveWidgetData<bool>("playing", playing);

      await _syncCover(track);
      await _syncTheme(track);

      final pins = GetIt.instance<ShortcutService>().pins;
      await HomeWidget.saveWidgetData<String>(
        "pins",
        jsonEncode([
          for (final pin in pins) {"id": pin.itemId, "name": pin.name, "subtitle": pin.subtitle ?? ""},
        ]),
      );

      await HomeWidget.updateWidget(androidName: _androidProvider, iOSName: _iosWidgetName);
    } catch (e) {
      _log.fine("Widget sync failed: $e");
    }
  }

  /// Copies the current track's cover art into the shared app-group container
  /// so the native widget can display it. Stores the on-disk path under "cover".
  Future<void> _syncCover(BaseItemDto? track) async {
    if (track == null) {
      await HomeWidget.saveWidgetData<String>("cover", "");
      return;
    }

    if (await _writeCover(track)) return;

    Future.delayed(const Duration(milliseconds: 1500), () async {
      final current = GetIt.instance<QueueService>().getQueue().currentTrack?.baseItem;
      if (current?.id != track.id) return; // track changed again; let its sync win
      if (await _writeCover(track)) {
        await HomeWidget.updateWidget(androidName: _androidProvider, iOSName: _iosWidgetName);
      }
    });
  }

  /// Writes the track's cached cover file into the app group. Returns true on
  /// success, false if the image isn't available yet (previous cover is kept).
  Future<bool> _writeCover(BaseItemDto track) async {
    try {
      final uri = GetIt.instance<ProviderContainer>().read(albumImageProvider(AlbumImageRequest(item: track))).uri;

      if (uri == null || uri.scheme != "file") return false;

      final file = File(uri.toFilePath());
      if (!await file.exists()) return false;

      final bytes = await file.readAsBytes();
      await HomeWidget.saveFile("cover", bytes, extension: _coverExtension(file.path));
      return true;
    } catch (e) {
      _log.fine("Widget cover sync failed (keeping previous cover): $e");
      return false;
    }
  }

  static String _coverExtension(String filePath) {
    final name = filePath.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return "img";
    final ext = name.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : "img";
  }

  Future<void> _syncTheme(BaseItemDto? track) async {
    try {
      final scheme = track == null ? null : GetIt.instance<ProviderContainer>().read(localThemeProvider);

      if (scheme == null) {
        await HomeWidget.saveWidgetData<String>("bgColor", "");
        await HomeWidget.saveWidgetData<String>("accentColor", "");
        return;
      }

      await HomeWidget.saveWidgetData<String>("bgColor", _hex(scheme.surface));
      await HomeWidget.saveWidgetData<String>("accentColor", _hex(scheme.primary));
    } catch (e) {
      _log.fine("Widget theme sync failed: $e");
      await HomeWidget.saveWidgetData<String>("bgColor", "");
      await HomeWidget.saveWidgetData<String>("accentColor", "");
    }
  }

  static String _hex(Color color) => (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
}
