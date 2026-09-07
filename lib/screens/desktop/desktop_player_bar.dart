import 'package:audio_service/audio_service.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/components/PlayerScreen/progress_slider.dart';
import 'package:diapason/components/PlayerScreen/spectrum_visualizer.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/desktop/desktop_track_info.dart';
import 'package:diapason/screens/desktop/desktop_transport_controls.dart';
import 'package:diapason/services/connect/connect_remote_controller.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/current_album_image_provider.dart';
import 'package:diapason/services/media_state_stream.dart';
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
  });

  final bool lyricsOpen;
  final VoidCallback onToggleLyrics;
  final VoidCallback onMiniPlayer;
  final VoidCallback onFullscreen;

  /// Opens an already-resolved album or artist as a detail page in the main
  /// content area.
  final void Function(BaseItemDto item, {required bool isArtist}) onOpenLibraryItem;

  @override
  ConsumerState<DesktopPlayerBar> createState() => _DesktopPlayerBarState();
}

class _DesktopPlayerBarState extends ConsumerState<DesktopPlayerBar> {
  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  double _volume = 1.0;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return Container(
      height: 148,
      decoration: BoxDecoration(
        color: p.bgSecondary,
        border: Border(top: BorderSide(color: p.borderSubtle)),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 260,
            child: IgnorePointer(
              child: Opacity(opacity: 0.6, child: RepaintBoundary(child: const SpectrumVisualizer())),
            ),
          ),
          // When Diapason Connect is driving another device, this same bar shows
          // that device's track and its controls send commands there instead.
          ValueListenableBuilder<RemoteNowPlaying?>(
            valueListenable: GetIt.instance<ConnectRemoteController>().nowPlaying,
            builder: (context, remote, _) => remote == null ? _content(p) : _remoteContent(p, remote),
          ),
        ],
      ),
    );
  }

  Widget _remoteContent(DesktopPalette p, RemoteNowPlaying remote) {
    final connect = GetIt.instance<ConnectRemoteController>();
    return Row(
      children: [
        Expanded(
          child: _trackInfoLayout(
            p,
            art: remote.item == null
                ? Container(
                    decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(6)),
                    child: Icon(TablerIcons.device_speaker, color: p.textTertiary),
                  )
                : ClipRRect(borderRadius: BorderRadius.circular(6), child: AlbumImage(item: remote.item)),
            onArtTap: null,
            title: remote.title,
            artist: remote.artist,
            extra: Row(
              children: [
                Icon(TablerIcons.device_speaker, size: 11, color: p.accent),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    "Playing on ${remote.device.name}",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.accent, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DesktopTransportControls(
                playing: remote.playing,
                playSize: 32,
                iconSize: 26,
                // Shuffle/repeat aren't part of the Connect protocol.
                showShuffleRepeat: false,
                onToggle: connect.togglePlayback,
                onNext: connect.next,
                onPrevious: connect.previous,
              ),
              const SizedBox(height: 4),
              DesktopSeekBar(
                duration: remote.duration,
                positionListenable: connect.position,
                onSeek: connect.seek,
              ),
            ],
          ),
        ),
        Expanded(child: _remoteRightControls(p, remote, connect)),
      ],
    );
  }

  Widget _remoteRightControls(DesktopPalette p, RemoteNowPlaying remote, ConnectRemoteController connect) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: p.textSecondary),
            onPressed: connect.disconnect,
            icon: const Icon(TablerIcons.plug_connected_x, size: 16),
            label: const Text("Disconnect"),
          ),
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
                value: remote.volume.clamp(0.0, 1.0),
                onChanged: connect.setVolume,
              ),
            ),
          ),
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
    return _trackInfoLayout(
      p,
      art: item == null
          ? Container(
              decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(6)),
              child: Icon(TablerIcons.disc, color: p.textTertiary),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AlbumImage(imageListenable: currentAlbumImageProvider),
            ),
      onArtTap: item == null ? null : widget.onFullscreen,
      title: item?.title ?? "No track playing",
      artist: item?.artist ?? "—",
      onTitleTap: albumId == null ? null : () => _openResolved(albumId, isArtist: false),
      onArtistTap: artistId == null ? null : () => _openResolved(artistId, isArtist: true),
      extra: const DesktopTrackInfoLine(),
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: onArtTap,
            child: SizedBox(width: 76, height: 76, child: art),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line(
                  title,
                  TextStyle(color: p.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                  onTitleTap,
                ),
                const SizedBox(height: 2),
                line(
                  artist,
                  TextStyle(color: p.textSecondary, fontSize: 12),
                  onArtistTap,
                ),
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
          IconButton(
            iconSize: 18,
            tooltip: "Fullscreen player",
            color: p.textSecondary,
            icon: const Icon(TablerIcons.arrows_maximize),
            onPressed: widget.onFullscreen,
          ),
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
                value: _volume,
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
