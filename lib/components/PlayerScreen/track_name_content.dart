import 'package:diapason/components/live_badge.dart';
import 'package:diapason/models/radio_station.dart';
import 'package:diapason/services/radio/radio_now_playing.dart';
import 'package:diapason/components/AddToPlaylistScreen/add_to_playlist_button.dart';
import 'package:diapason/components/PlayerScreen/album_chip.dart';
import 'package:diapason/components/PlayerScreen/artist_chip.dart';
import 'package:diapason/components/PlayerScreen/player_buttons_more.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/jellyfin_models.dart' as jellyfin_models;
import 'package:diapason/screens/player_screen.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/scrolling_text_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TrackNameContent extends ConsumerWidget {
  const TrackNameContent(this.controller, {super.key});

  final PlayerHideableController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(QueueService.queueProvider);

    if (queue?.currentTrack == null) {
      return const CircularProgressIndicator();
    }
    final currentTrack = queue!.currentTrack!;

    final jellyfin_models.BaseItemDto trackBaseItemDto = currentTrack.baseItem;
    final isLive = RadioStation.isLiveItem(trackBaseItemDto);
    final nowPlaying = isLive ? ref.watch(radioNowPlayingProvider).value : null;
    final shownTitle = nowPlaying?.title ?? currentTrack.item.title;

    Widget getContent(BoxConstraints constraints, double padding) => Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth - padding),
          child: Semantics.fromProperties(
            properties: SemanticsProperties(label: "$shownTitle (${AppLocalizations.of(context)!.title})"),
            excludeSemantics: true,
            container: true,
            child: Consumer(
              builder: (context, ref, _) {
                final text = shownTitle;
                final isTwoLineMode = controller.shouldShow(PlayerHideable.twoLineTitle);

                final textStyle = TextStyle(
                  fontSize: 20,
                  height: 1.2,
                  fontWeight: Theme.brightnessOf(context) == Brightness.light ? FontWeight.w500 : FontWeight.w500,
                );

                final textSpan = TextSpan(text: text, style: textStyle);
                final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr, maxLines: 2)
                  ..layout(maxWidth: 280);

                final wouldOverflow = textPainter.didExceedMaxLines;
                textPainter.dispose();

                if (!isTwoLineMode) {
                  return Text(
                    text,
                    style: textStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  );
                } else {
                  if (wouldOverflow && ref.watch(finampSettingsProvider.oneLineMarqueeTextButton)) {
                    return SizedBox(
                      width: 280,
                      height: 30,
                      child: ScrollingTextHelper(
                        id: ValueKey("${currentTrack.item.id}-$shownTitle"),
                        text: text,
                        style: textStyle,
                        alignment: TextAlign.center,
                      ),
                    );
                  } else {
                    return SizedBox(
                      height: 48.0,
                      child: Center(
                        child: Text(
                          text,
                          style: textStyle,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  }
                }
              },
            ),
          ),
        ),
        if (isLive)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const LiveBadge(compact: true),
                if (nowPlaying?.artist != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      nowPlaying!.artist!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            PlayerButtonsMore(item: trackBaseItemDto, queueItem: currentTrack),
            Flexible(
              child: ArtistChips(
                baseItem: trackBaseItemDto,
                backgroundColor: IconTheme.of(context).color!.withValues(alpha: 0.1),
              ),
            ),
            AddToPlaylistButton(item: trackBaseItemDto, queueItem: currentTrack),
          ],
        ),
        Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            child: AlbumChips(
              baseItem: trackBaseItemDto,
              backgroundColor: IconTheme.of(context).color!.withValues(alpha: 0.1),
              key: trackBaseItemDto.album == null ? null : ValueKey("${trackBaseItemDto.album}-album"),
            ),
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        double padding = ((constraints.maxWidth - 260) / 4).clamp(0, 20);
        return Padding(
          padding: EdgeInsets.only(left: padding, right: padding, bottom: 4.0),
          child: getContent(constraints, padding),
        );
      },
    );
  }
}
