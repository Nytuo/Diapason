import 'package:audio_service/audio_service.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

String formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString();
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return "$m:$s";
}

class DesktopTransportControls extends StatelessWidget {
  const DesktopTransportControls({
    super.key,
    required this.playing,
    this.playSize = 26,
    this.iconSize = 22,
    this.showShuffleRepeat = true,
    this.onToggle,
    this.onNext,
    this.onPrevious,
  });

  final bool playing;
  final double playSize;
  final double iconSize;
  final bool showShuffleRepeat;

  /// Override the transport actions to drive something other than the local
  /// player — used when Diapason Connect is controlling another device.
  final VoidCallback? onToggle;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    final queueService = GetIt.instance<QueueService>();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (showShuffleRepeat)
          StreamBuilder<FinampPlaybackOrder>(
            stream: queueService.getPlaybackOrderStream(),
            initialData: FinampPlaybackOrder.linear,
            builder: (context, snap) {
              final shuffled = snap.data == FinampPlaybackOrder.shuffled;
              return IconButton(
                iconSize: 18,
                color: shuffled ? p.accent : p.textSecondary,
                icon: const Icon(TablerIcons.arrows_shuffle),
                onPressed: () => queueService.togglePlaybackOrder(),
              );
            },
          ),
        IconButton(
          iconSize: iconSize,
          color: p.textPrimary,
          tooltip: "Previous",
          icon: const Icon(TablerIcons.player_skip_back),
          onPressed: onPrevious ?? () => audioHandler.skipToPrevious(forceSkip: true),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Tooltip(
            message: "Play/Pause",
            child: SizedBox(
              width: playSize + 20,
              height: playSize + 20,
              child: Material(
                borderRadius: BorderRadius.circular(14),
                color: p.accent.withOpacity(0.15),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onToggle ?? () => audioHandler.togglePlayback(),
                  child: Icon(
                    playing ? TablerIcons.player_pause : TablerIcons.player_play,
                    size: playSize,
                    color: p.accent,
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          iconSize: iconSize,
          color: p.textPrimary,
          tooltip: "Next",
          icon: const Icon(TablerIcons.player_skip_forward),
          onPressed: onNext ?? () => audioHandler.skipToNext(),
        ),
        if (showShuffleRepeat)
          StreamBuilder<FinampLoopMode>(
            stream: queueService.getLoopModeStream(),
            initialData: FinampLoopMode.none,
            builder: (context, snap) {
              final mode = snap.data ?? FinampLoopMode.none;
              return IconButton(
                iconSize: 18,
                color: mode == FinampLoopMode.none ? p.textSecondary : p.accent,
                icon: Icon(mode == FinampLoopMode.one ? TablerIcons.repeat_once : TablerIcons.repeat),
                onPressed: () => queueService.toggleLoopMode(),
              );
            },
          ),
      ],
    );
  }
}

class DesktopSeekBar extends StatefulWidget {
  const DesktopSeekBar({
    super.key,
    required this.duration,
    this.compact = false,
    this.positionListenable,
    this.onSeek,
  });

  final Duration duration;
  final bool compact;

  /// Position source / seek target. Both default to the local player; supply
  /// them to drive a Connect-controlled device instead.
  final ValueListenable<Duration>? positionListenable;
  final ValueChanged<Duration>? onSeek;

  @override
  State<DesktopSeekBar> createState() => _DesktopSeekBarState();
}

class _DesktopSeekBarState extends State<DesktopSeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final listenable = widget.positionListenable;
    if (listenable != null) {
      return ValueListenableBuilder<Duration>(
        valueListenable: listenable,
        builder: (context, position, _) => _bar(context, position),
      );
    }

    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    return StreamBuilder<Duration>(
      stream: AudioService.position,
      initialData: audioHandler.playbackState.value.position,
      builder: (context, snapshot) => _bar(context, snapshot.data ?? Duration.zero),
    );
  }

  Widget _bar(BuildContext context, Duration position) {
    final p = DesktopThemeScope.of(context);
    final totalMs = widget.duration.inMilliseconds;
    final value = _dragValue ?? (totalMs == 0 ? 0.0 : (position.inMilliseconds / totalMs).clamp(0.0, 1.0));

    void seek(double v) {
      final to = Duration(milliseconds: (v * totalMs).round());
      if (widget.onSeek != null) {
        widget.onSeek!(to);
      } else {
        GetIt.instance<MusicPlayerBackgroundTask>().seek(to);
      }
      setState(() => _dragValue = null);
    }

    final slider = SliderTheme(
      data: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: p.accent,
        inactiveTrackColor: p.surface,
        thumbColor: p.accent,
        overlayShape: SliderComponentShape.noOverlay,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      child: Slider(
        value: value.toDouble(),
        onChanged: totalMs == 0 ? null : (v) => setState(() => _dragValue = v),
        onChangeEnd: totalMs == 0 ? null : seek,
      ),
    );

    return Row(
      children: [
        const SizedBox(width: 8),
        Text(formatDuration(position), style: TextStyle(color: p.textTertiary, fontSize: 11)),
        Expanded(child: slider),
        Text(formatDuration(widget.duration), style: TextStyle(color: p.textTertiary, fontSize: 11)),
        const SizedBox(width: 8),
      ],
    );
  }
}
