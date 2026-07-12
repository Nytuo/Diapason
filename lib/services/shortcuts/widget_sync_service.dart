import 'dart:convert';
import 'dart:io';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/shortcuts/shortcut_service.dart';
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
}
