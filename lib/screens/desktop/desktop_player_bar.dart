import 'package:diapason/l10n/app_localizations.dart';
import 'package:audio_service/audio_service.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/components/PlayerScreen/progress_slider.dart';
import 'package:diapason/components/PlayerScreen/spectrum_visualizer.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/screens/desktop/desktop_kit.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/desktop/desktop_track_info.dart';
import 'package:diapason/screens/desktop/desktop_transport_controls.dart';
import 'package:diapason/components/connect_devices.dart';
import 'package:diapason/services/connect/remote_playback.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/current_album_image_provider.dart';
import 'package:diapason/services/media_state_stream.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class DesktopPlayerBar extends ConsumerStatefulWidget {
  const DesktopPlayerBar({
    super.key,
    required this.lyricsOpen,
    required this.onToggleLyrics,
    required this.onMiniPlayer,
    required this.onFullscreen,
    required this.onOpenLibraryItem,
    this.onOpenVisualizer,
  });

  final bool lyricsOpen;
  final VoidCallback onToggleLyrics;
  final VoidCallback onMiniPlayer;
  final VoidCallback onFullscreen;

  /// Opens the animated visual page; null hides the button.
  final VoidCallback? onOpenVisualizer;

  /// Opens an already-resolved album or artist as a detail page in the main
  /// content area.
  final void Function(BaseItemDto item, {required bool isArtist}) onOpenLibraryItem;

  @override
  ConsumerState<DesktopPlayerBar> createState() => _DesktopPlayerBarState();
}

class _DesktopPlayerBarState extends ConsumerState<DesktopPlayerBar> {
  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  double _volume = FinampSettingsHelper.finampSettings.currentVolume.clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return DesktopPanel(
      chrome: true,
      radius: DesktopMetrics.radiusPlayer,
      height: DesktopMetrics.playerBarHeight,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          if (!p.reduceEffects)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 260,
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.6,
                  child: RepaintBoundary(child: const SpectrumVisualizer(placement: SpectrumPlacement.strip)),
                ),
              ),
            ),
          // While Diapason Connect plays on another device, this same bar shows that device: the queue and
          // player state mirror it and every control is sent there (see RemotePlayback).
          _content(p),
        ],
      ),
    );
  }

  Widget _content(DesktopPalette p) {
    return StreamBuilder<MediaState>(
      stream: mediaStateStream,
      initialData: MediaState(
        _audioHandler.mediaItem.valueOrNull,
        _audioHandler.playbackState.value,
        _audioHandler.fadeState.value,
      ),
      builder: (context, snapshot) {
        final state = snapshot.data!;
        final item = state.mediaItem;
        final playing = state.playbackState.playing;
        return Row(
          children: [
            Expanded(child: _trackInfo(context, p, item)),
            Expanded(
              flex: 2,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  DesktopTransportControls(playing: playing, playSize: 32, iconSize: 26),
                  const SizedBox(height: 4),
                  DesktopSeekBar(duration: item?.duration ?? Duration.zero, chapters: chaptersFromMediaItem(item)),
                ],
              ),
            ),
            Expanded(child: _rightControls(context, p)),
          ],
        );
      },
    );
  }

  Widget _trackInfo(BuildContext context, DesktopPalette p, MediaItem? item) {
    final base = _baseItemOf(item);
    final artistId = _firstArtistId(base);
    final albumId = base?.albumId;
    // The big cover in the sidebar already shows the art.
    final bigCover = ref.watch(finampSettingsProvider.desktopBigCoverArt) && item != null;
    return _trackInfoLayout(
      p,
      showArt: !bigCover,
      art: item == null
          ? Container(
              decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(6)),
              child: Icon(TablerIcons.disc, color: p.textTertiary),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(DesktopMetrics.radiusArtSmall),
              child: AlbumImage(imageListenable: currentAlbumImageProvider),
            ),
      // Fullscreen has its own button; tapping the art toggles the big sidebar cover.
      onArtTap: item == null
          ? null
          : () => FinampSetters.setDesktopBigCoverArt(!ref.read(finampSettingsProvider.desktopBigCoverArt)),
      title: item?.title ?? "No track playing",
      artist: item?.artist ?? "—",
      onTitleTap: albumId == null ? null : () => _openResolved(albumId, isArtist: false),
      onArtistTap: artistId == null ? null : () => _openResolved(artistId, isArtist: true),
      extra: ConnectTargetBuilder(
        builder: (context, device) => device == null
            ? const DesktopTrackInfoLine()
            : const ConnectPlayingOnBanner(padding: EdgeInsets.only(top: 2)),
      ),
    );
  }

  BaseItemDto? _baseItemOf(MediaItem? item) {
    final json = item?.extras?["itemJson"];
    if (json is! Map) return null;
    try {
      return BaseItemDto.fromJson(json.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  BaseItemId? _firstArtistId(BaseItemDto? base) {
    if (base == null) return null;
    if (base.artistItems?.isNotEmpty ?? false) return base.artistItems!.first.id;
    if (base.albumArtists?.isNotEmpty ?? false) return base.albumArtists!.first.id;
    return null;
  }

  Future<void> _openResolved(BaseItemId id, {required bool isArtist}) async {
    try {
      final resolved = await GetIt.instance<AggregateBackend>().getItemById(id);
      if (resolved != null && mounted) {
        widget.onOpenLibraryItem(resolved, isArtist: isArtist);
      }
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }

  Widget _trackInfoLayout(
    DesktopPalette p, {
    required bool showArt,
    required Widget art,
    required VoidCallback? onArtTap,
    required String title,
    required String artist,
    required Widget extra,
    VoidCallback? onTitleTap,
    VoidCallback? onArtistTap,
  }) {
    Widget line(String text, TextStyle style, VoidCallback? onTap) {
      final label = Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
      if (onTap == null) return label;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(decoration: TextDecoration.underline, decorationColor: style.color),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 16),
      child: Row(
        children: [
          AnimatedSize(
            duration: p.motion(const Duration(milliseconds: 220)),
            curve: Curves.easeOutCubic,
            child: showArt
                ? Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: MouseRegion(
                      cursor: onArtTap == null ? MouseCursor.defer : SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: onArtTap,
                        child: SizedBox(width: 68, height: 68, child: art),
                      ),
                    ),
                  )
                : const SizedBox(height: 68),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line(title, p.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700), onTitleTap),
                const SizedBox(height: 2),
                line(artist, p.caption.copyWith(fontSize: 12.5), onArtistTap),
                const SizedBox(height: 2),
                extra,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rightControls(BuildContext context, DesktopPalette p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            iconSize: 18,
            tooltip: "Lyrics",
            color: widget.lyricsOpen ? p.accent : p.textSecondary,
            icon: const Icon(TablerIcons.microphone_2),
            onPressed: widget.onToggleLyrics,
          ),
          IconButton(
            iconSize: 18,
            tooltip: "Mini player",
            color: p.textSecondary,
            icon: const Icon(TablerIcons.picture_in_picture),
            onPressed: widget.onMiniPlayer,
          ),
          if (widget.onOpenVisualizer != null)
            IconButton(
              iconSize: 18,
              tooltip: AppLocalizations.of(context)!.visualAnimatedOpen,
              color: p.textSecondary,
              icon: const Icon(TablerIcons.sparkles),
              onPressed: widget.onOpenVisualizer,
            ),
          IconButton(
            iconSize: 18,
            tooltip: "Fullscreen player",
            color: p.textSecondary,
            icon: const Icon(TablerIcons.arrows_maximize),
            onPressed: widget.onFullscreen,
          ),
          ConnectDeviceButton(size: 18, color: p.textSecondary, activeColor: p.accent),
          const SizedBox(width: 4),
          Icon(TablerIcons.volume, size: 18, color: p.textSecondary),
          SizedBox(
            width: 100,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                activeTrackColor: p.accent,
                inactiveTrackColor: p.surface,
                thumbColor: p.accent,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                // The controlled device's volume while playing on another device.
                value: (RemotePlayback.current?.active ?? false)
                    ? RemotePlayback.current!.volume.clamp(0.0, 1.0)
                    : _volume,
                onChanged: (v) {
                  setState(() => _volume = v);
                  _audioHandler.setVolume(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
