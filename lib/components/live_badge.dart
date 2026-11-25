import 'package:audio_service/audio_service.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/jellyfin_models.dart' as jellyfin_models;
import 'package:diapason/models/radio_station.dart';
import 'package:flutter/material.dart';

/// Whether the player's [MediaItem] is a live stream (internet radio).
bool isLiveMediaItem(MediaItem? item) {
  final json = item?.extras?["itemJson"];
  if (json is! Map<String, dynamic>) return false;
  return RadioStation.isLiveItem(jellyfin_models.BaseItemDto.fromJson(json));
}

/// A small "LIVE" pill, shown instead of a seek bar for radio stations.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 8, vertical: compact ? 1 : 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: compact ? 6 : 8, color: Theme.of(context).colorScheme.onError),
          SizedBox(width: compact ? 3 : 5),
          Text(
            AppLocalizations.of(context)!.radioStationsLive,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onError,
              fontSize: compact ? 10 : 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Stands in for the progress slider while a live stream plays: a full,
/// non-interactive bar with the "LIVE" badge and the time listened so far.
class LiveProgressIndicator extends StatelessWidget {
  const LiveProgressIndicator({super.key, required this.position, this.showDuration = true});

  final Duration position;
  final bool showDuration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String two(int n) => n.toString().padLeft(2, "0");
    final elapsed = position.inHours > 0
        ? "${position.inHours}:${two(position.inMinutes % 60)}:${two(position.inSeconds % 60)}"
        : "${position.inMinutes}:${two(position.inSeconds % 60)}";
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 24,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: 1,
                minHeight: 3.5,
                color: theme.colorScheme.primary.withValues(alpha: 0.6),
                backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.15),
              ),
            ),
          ),
        ),
        if (showDuration)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(elapsed, style: theme.textTheme.bodySmall),
              const LiveBadge(compact: true),
            ],
          ),
      ],
    );
  }
}
