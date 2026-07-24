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

class _DesktopSeekBarState extends State<DesktopSeekBar> with SingleTickerProviderStateMixin {
  double? _dragValue;
  late final AnimationController _loadingController;

  @override
  void initState() {
    super.initState();
    _loadingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _loadingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    
    return StreamBuilder<PlaybackState>(
      stream: audioHandler.playbackState,
      initialData: audioHandler.playbackState.value,
      builder: (context, stateSnap) {
        final state = stateSnap.data;
        final buffered = widget.positionListenable != null ? Duration.zero : (state?.bufferedPosition ?? Duration.zero);
        final loading = widget.positionListenable == null &&
            (state?.processingState == AudioProcessingState.loading ||
                state?.processingState == AudioProcessingState.buffering);

        final listenable = widget.positionListenable;
        if (listenable != null) {
          return ValueListenableBuilder<Duration>(
            valueListenable: listenable,
            builder: (context, position, _) => _bar(context, position, buffered, loading),
          );
        }

        return StreamBuilder<Duration>(
          stream: AudioService.position,
          initialData: audioHandler.playbackState.value.position,
          builder: (context, snapshot) => _bar(context, snapshot.data ?? Duration.zero, buffered, loading),
        );
      },
    );
  }

  Widget _bar(BuildContext context, Duration position, Duration buffered, bool loading) {
    final p = DesktopThemeScope.of(context);
    final totalMs = widget.duration.inMilliseconds;
    final value = _dragValue ?? (totalMs == 0 ? 0.0 : (position.inMilliseconds / totalMs).clamp(0.0, 1.0));
    final bufferedValue = totalMs == 0 ? 0.0 : (buffered.inMilliseconds / totalMs).clamp(0.0, 1.0);

    final showIndeterminate = loading && (totalMs == 0 || position <= Duration.zero);

    void seek(double v) {
      final to = Duration(milliseconds: (v * totalMs).round());
      if (widget.onSeek != null) {
        widget.onSeek!(to);
      } else {
        GetIt.instance<MusicPlayerBackgroundTask>().seek(to);
      }
      setState(() => _dragValue = null);
    }

    final Widget track;
    if (showIndeterminate) {
      track = SizedBox(
        height: 16,
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: AnimatedBuilder(
              animation: _loadingController,
              builder: (context, _) => CustomPaint(
                size: const Size(double.infinity, 4),
                painter: _IndeterminatePainter(
                  progress: _loadingController.value,
                  track: p.surface,
                  accent: p.accent,
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      track = SliderTheme(
        data: SliderThemeData(
          trackHeight: 4,
          activeTrackColor: p.accent,
          inactiveTrackColor: p.surface,
          secondaryActiveTrackColor: p.accent.withOpacity(0.28),
          thumbColor: p.accent,
          overlayShape: SliderComponentShape.noOverlay,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        ),
        child: Slider(
          value: value.toDouble(),
          secondaryTrackValue: bufferedValue > value ? bufferedValue.toDouble() : null,
          onChanged: totalMs == 0 ? null : (v) => setState(() => _dragValue = v),
          onChangeEnd: totalMs == 0 ? null : seek,
        ),
      );
    }

    return Row(
      children: [
        const SizedBox(width: 8),
        Text(
          showIndeterminate ? "--:--" : formatDuration(position),
          style: TextStyle(color: p.textTertiary, fontSize: 11),
        ),
        Expanded(child: track),
        Text(formatDuration(widget.duration), style: TextStyle(color: p.textTertiary, fontSize: 11)),
        const SizedBox(width: 8),
      ],
    );
  }
}

class _IndeterminatePainter extends CustomPainter {
  _IndeterminatePainter({required this.progress, required this.track, required this.accent});

  final double progress;
  final Color track;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final trackPaint = Paint()..color = track;
    canvas.drawRect(Offset.zero & size, trackPaint);

    final segWidth = size.width * 0.35;
    final travel = size.width + segWidth;
    final start = progress * travel - segWidth;

    final rect = Rect.fromLTWH(start, 0, segWidth, size.height);
    final shader = LinearGradient(
      colors: [accent.withOpacity(0.0), accent, accent.withOpacity(0.0)],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(rect);
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_IndeterminatePainter old) =>
      old.progress != progress || old.track != track || old.accent != accent;
}
