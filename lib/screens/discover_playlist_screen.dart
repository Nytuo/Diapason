import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/components/AlbumScreen/download_button.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/discovery/discovery_service.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class _YouTubePicker extends StatelessWidget {
  const _YouTubePicker({required this.track, required this.candidates});

  final DiscoveredTrack track;
  final List<BaseItemDto> candidates;

  static String _duration(Duration? duration) {
    if (duration == null) return "";
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, "0");
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    final youtube = GetIt.instance<YouTubeService>();
    return AlertDialog(
      title: Text(AppLocalizations.of(context)!.discoverPickVersion),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("${track.artist} — ${track.title}", style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (context, index) {
                  final candidate = candidates[index];
                  final thumbnail = youtube.thumbnail(candidate);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: SizedBox(
                      width: 72,
                      height: 48,
                      child: thumbnail == null
                          ? const Icon(TablerIcons.brand_youtube)
                          : Image.network(
                              thumbnail.toString(),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const Icon(TablerIcons.brand_youtube),
                            ),
                    ),
                    title: Text(
                      candidate.name ?? AppLocalizations.of(context)!.discoverUnknownTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        candidate.albumArtist,
                        _duration(candidate.runTimeTicksDuration()),
                      ].where((s) => s != null && s.isNotEmpty).join(" · "),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).pop<BaseItemDto>(candidate),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}

class _Entry {
  _Entry(this.requested);

  final DiscoveredTrack requested;
  BaseItemDto? resolved;
  bool fromYouTube = false;
  bool searching = false;

  bool missing = false;
}

class DiscoverPlaylistScreen extends ConsumerStatefulWidget {
  const DiscoverPlaylistScreen({super.key, required this.playlist});

  final DiscoverPlaylist playlist;

  @override
  ConsumerState<DiscoverPlaylistScreen> createState() => _DiscoverPlaylistScreenState();
}

class _DiscoverPlaylistScreenState extends ConsumerState<DiscoverPlaylistScreen> {
  DiscoveryService get _discovery => GetIt.instance<DiscoveryService>();
  YouTubeService get _youtube => GetIt.instance<YouTubeService>();

  List<_Entry>? _entries;
  Object? _error;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _entries = null;
      _error = null;
    });
    try {
      final requested = await _discovery.discoverPlaylistTracks(widget.playlist);
      final entries = requested.map(_Entry.new).toList();
      final matches = await _discovery.matchInLibrary(requested);
      for (var i = 0; i < entries.length; i++) {
        entries[i].resolved = matches[i];
      }
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  List<BaseItemDto> get _playable => (_entries ?? []).map((e) => e.resolved).nonNulls.toList();
  List<_Entry> get _unresolved => (_entries ?? []).where((e) => e.resolved == null && !e.missing).toList();

  QueueItemSource get _source => QueueItemSource(
    type: QueueItemSourceType.unknown,
    name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: widget.playlist.title),
    id: BaseItemId(widget.playlist.id),
  );

  Future<void> _play(List<BaseItemDto> tracks, {int? startingIndex, bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: _source,
      startingIndex: startingIndex,
      order: shuffle ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear,
    );
  }

  Future<void> _pickFromYouTube(_Entry entry) async {
    if (entry.searching) return;
    if (!isYouTubeAvailable) {
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.discoverYoutubeNotSetUp);
      return;
    }
    if (_youtube.isRateLimited) {
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.discoverRateLimitedRetry);
      return;
    }

    setState(() => entry.searching = true);
    List<BaseItemDto> candidates;
    try {
      candidates = await _discovery.youtubeCandidates(entry.requested, throwOnError: true);
    } catch (e) {
      if (mounted) setState(() => entry.searching = false);
      GlobalSnackbar.error(e);
      return;
    }
    if (!mounted) return;
    setState(() => entry.searching = false);

    if (candidates.isEmpty) {
      setState(() => entry.missing = true);
      GlobalSnackbar.message(
        (context) => _youtube.isRateLimited
            ? AppLocalizations.of(context)!.discoverRateLimited
            : AppLocalizations.of(context)!.discoverNoYoutubeResults,
      );
      return;
    }

    final chosen = await showDialog<BaseItemDto>(
      context: context,
      builder: (_) => _YouTubePicker(track: entry.requested, candidates: candidates),
    );
    if (chosen == null || !mounted) return;

    setState(() {
      entry.resolved = chosen;
      entry.fromYouTube = true;
      entry.missing = false;
    });
  }

  Future<void> _downloadAll() async {
    final tracks = _playable;
    if (tracks.isEmpty || _downloading) return;

    final settings = FinampSettingsHelper.finampSettings;
    String? location = settings.defaultDownloadLocation;
    if (!settings.downloadLocationsMap.containsKey(location)) location = null;
    location ??= settings.downloadLocationsMap.values
        .where((l) => l.baseDirectory != DownloadLocationType.internalDocuments)
        .map((l) => l.id)
        .firstOrNull;
    if (location == null) {
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.discoverPickDownloadLocation);
      return;
    }

    final profile = settings.shouldTranscodeDownloads == TranscodeDownloadsSetting.always
        ? settings.downloadTranscodingProfile
        : DownloadProfile(transcodeCodec: FinampTranscodingCodec.original);
    profile.downloadLocationId = location;
    FinampSetters.setLastUsedDownloadLocationId(location);

    final viewId = GetIt.instance<FinampUserHelper>().currentUser?.currentViewId;
    final downloads = GetIt.instance<DownloadsService>();

    setState(() => _downloading = true);
    try {
      for (final track in tracks) {
        await downloads.addDownload(
          stub: DownloadStub.fromItem(type: DownloadItemType.track, item: track),
          transcodeProfile: profile,
          viewId: viewId,
        );
      }
      GlobalSnackbar.message(
        (context) => AppLocalizations.of(context)!.discoverQueuedDownloads(tracks.length),
        isConfirmation: true,
      );
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.title),
        leading: FinampAppBarBackButton(),
        actions: [IconButton(icon: const Icon(TablerIcons.refresh), onPressed: _load)],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppLocalizations.of(context)!.discoverLoadFailed, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _load,
                icon: Icon(TablerIcons.refresh),
                label: Text(AppLocalizations.of(context)!.discoverRetry),
              ),
            ],
          ),
        ),
      );
    }

    final entries = _entries;
    if (entries == null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(AppLocalizations.of(context)!.discoverMatching, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if (entries.isEmpty) {
      return Center(
        child: Padding(padding: EdgeInsets.all(32.0), child: Text(AppLocalizations.of(context)!.discoverEmpty)),
      );
    }

    return Column(
      children: [
        _actions(entries),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(itemCount: entries.length, itemBuilder: (context, index) => _row(entries[index])),
        ),
      ],
    );
  }

  Widget _row(_Entry entry) {
    final resolved = entry.resolved;
    final tracks = _playable;

    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: resolved == null
            ? Center(
                child: Icon(
                  entry.missing ? TablerIcons.music_off : TablerIcons.music,
                  color: Theme.of(context).disabledColor,
                ),
              )
            : AlbumImage(item: resolved),
      ),
      title: Text(
        entry.requested.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: resolved == null ? TextStyle(color: Theme.of(context).disabledColor) : null,
      ),
      subtitle: Text(
        switch (entry) {
          _ when entry.missing => AppLocalizations.of(context)!.discoverEntryNotFound(entry.requested.artist),
          _ when resolved == null => AppLocalizations.of(context)!.discoverEntryNotInLibrary(entry.requested.artist),
          _ when entry.fromYouTube => AppLocalizations.of(context)!.discoverEntryYoutube(entry.requested.artist),
          _ => entry.requested.artist,
        },
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: entry.searching
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : resolved == null
          ? !isYouTubeAvailable
                ? null
                : IconButton(
                    icon: const Icon(TablerIcons.brand_youtube),
                    tooltip: AppLocalizations.of(context)!.discoverPickMatch,
                    onPressed: () => _pickFromYouTube(entry),
                  )
          : DownloadButton(
              item: DownloadStub.fromItem(type: DownloadItemType.track, item: resolved),
            ),
      onTap: resolved == null
          ? (isYouTubeAvailable ? () => _pickFromYouTube(entry) : null)
          : () => _play(tracks, startingIndex: tracks.indexOf(resolved)),
    );
  }

  Widget _actions(List<_Entry> entries) {
    final playable = _playable;
    final missing = _unresolved.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context)!.discoverReadyCount(playable.length, entries.length) +
                (missing > 0
                    ? (isYouTubeAvailable
                          ? AppLocalizations.of(context)!.discoverNeedMatch(missing)
                          : AppLocalizations.of(context)!.discoverNotInLibraryCount(missing))
                    : ""),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: playable.isEmpty ? null : () => _play(playable),
                icon: const Icon(TablerIcons.player_play, size: 18),
                label: Text(AppLocalizations.of(context)!.discoverPlayAll),
              ),
              OutlinedButton.icon(
                onPressed: playable.isEmpty ? null : () => _play(playable, shuffle: true),
                icon: const Icon(TablerIcons.arrows_shuffle, size: 18),
                label: Text(AppLocalizations.of(context)!.discoverShuffle),
              ),
              OutlinedButton.icon(
                onPressed: (_downloading || playable.isEmpty) ? null : _downloadAll,
                icon: _downloading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(TablerIcons.download, size: 18),
                label: Text(
                  _downloading
                      ? AppLocalizations.of(context)!.discoverQueuing
                      : AppLocalizations.of(context)!.discoverDownloadAll,
                ),
              ),
            ],
          ),
          if (missing > 0 && isYouTubeAvailable) ...[
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context)!.discoverTapGreyed,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).disabledColor),
            ),
          ],
        ],
      ),
    );
  }
}
