import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/feedback_helper.dart';
import 'package:diapason/services/lyrics/lrclib_client.dart';
import 'package:diapason/services/lyrics/lyrics_offset_service.dart';
import 'package:diapason/services/lyrics/lyrics_sources.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// "Word sync" / "Synced" / "Plain", as a small pill.
class LyricsSyncBadge extends StatelessWidget {
  const LyricsSyncBadge(this.sync, {super.key, this.dense = false});

  final LyricsSync sync;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, icon) = switch (sync) {
      LyricsSync.word => (scheme.primary, scheme.onPrimary, TablerIcons.text_size),
      LyricsSync.line => (scheme.secondaryContainer, scheme.onSecondaryContainer, TablerIcons.clock),
      LyricsSync.plain => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, TablerIcons.align_left),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: 2),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Text(
            sync.label,
            style: TextStyle(color: foreground, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// The single entry point for everything about a track's lyrics: opens a panel with the source (automatic, another
/// found source, or a manual search) and, for synced lyrics, the timing shift. Shows the current shift when one is set.
class LyricsManageButton extends ConsumerWidget {
  const LyricsManageButton({
    super.key,
    required this.item,
    required this.automatic,
    required this.shown,
    this.showLabel = false,
  });

  final BaseItemDto item;

  /// What was picked automatically.
  final LyricsOption? automatic;

  /// What is on screen (the user's pick, or [automatic]).
  final LyricsOption? shown;

  /// Label the button "Lyrics options" even without a timing shift to show (used where there is no lyrics view).
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listenable = LyricsOffsetService.listenable(item.id);
    Widget button(int offset) {
      final color = Theme.of(context).textTheme.bodyLarge?.color;
      return TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: color, visualDensity: VisualDensity.compact),
        onPressed: () {
          FeedbackHelper.feedback(FeedbackType.selection);
          showLyricsManager(context, item: item, automatic: automatic, shown: shown);
        },
        icon: const Icon(TablerIcons.adjustments_horizontal, size: 20),
        label: offset != 0
            ? Text(LyricsOffsetService.format(offset))
            : showLabel
            ? const Text("Lyrics options")
            : const SizedBox.shrink(),
      );
    }

    if (listenable == null) return button(0);
    return ValueListenableBuilder(
      valueListenable: listenable,
      builder: (context, _, _) => button(LyricsOffsetService.offsetMs(item.id)),
    );
  }
}

Future<void> showLyricsManager(
  BuildContext context, {
  required BaseItemDto item,
  required LyricsOption? automatic,
  required LyricsOption? shown,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => _LyricsManagerSheet(item: item, automatic: automatic, shown: shown),
  );
}

class _LyricsManagerSheet extends ConsumerStatefulWidget {
  const _LyricsManagerSheet({required this.item, required this.automatic, required this.shown});

  final BaseItemDto item;
  final LyricsOption? automatic;
  final LyricsOption? shown;

  @override
  ConsumerState<_LyricsManagerSheet> createState() => _LyricsManagerSheetState();
}

class _LyricsManagerSheetState extends ConsumerState<_LyricsManagerSheet> {
  bool _searching = false;
  late final TextEditingController _query = TextEditingController(text: _initialQuery());
  List<LrclibMatch>? _results;
  bool _loading = false;

  String _initialQuery() {
    final artist = widget.item.artists?.firstOrNull ?? widget.item.albumArtist ?? "";
    return "$artist ${widget.item.name ?? ""}".trim();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text;
    if (query.trim().isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _results = null;
    });
    List<LrclibMatch> found;
    try {
      found = await GetIt.instance<LrclibClient>().search(query);
    } catch (_) {
      found = const [];
    }
    if (!mounted) return;
    setState(() {
      _results = found;
      _loading = false;
    });
  }

  Future<void> _pick(LyricsOption? option) async {
    ref.read(chosenLyricsProvider(widget.item.id).notifier).state = option;
    await GetIt.instance<LyricsSources>().choices.choose(widget.item.id, option?.origin);
    if (mounted) Navigator.of(context).pop();
  }

  /// A manual pick is one specific upload, which can't be re-found later: it only lasts for this session.
  void _pickMatch(LrclibMatch match) {
    ref.read(chosenLyricsProvider(widget.item.id).notifier).state = LyricsOption(
      origin: LyricsOrigin.lrclib,
      lyrics: match.lyrics,
      label: "LRCLIB · ${match.artist} – ${match.title}",
    );
    GetIt.instance<LyricsSources>().choices.choose(widget.item.id, null);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: inset),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _searching ? _buildSearch(context) : _buildMain(context),
          ),
        ),
      ),
    );
  }

  Widget _buildMain(BuildContext context) {
    final options = ref.watch(lyricsOptionsProvider((widget.item, widget.automatic)));
    final chosen = ref.watch(chosenLyricsProvider(widget.item.id));
    final shown = chosen ?? widget.automatic;
    final databases = LyricsSources.enabledDatabases.map((o) => o.databaseName).join(", ");
    final primary = Theme.of(context).colorScheme.primary;

    bool isShown(LyricsOption option) => shown != null && option.origin == shown.origin && option.label == shown.label;

    return ListView(
      key: const ValueKey("main"),
      shrinkWrap: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Text("Lyrics", style: Theme.of(context).textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text("Source", style: Theme.of(context).textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text("Your library, then $databases.", style: Theme.of(context).textTheme.bodySmall),
        ),
        ListTile(
          leading: const Icon(TablerIcons.wand),
          title: const Text("Automatic"),
          subtitle: Text(
            widget.automatic == null ? "Best available" : "Best available · now ${widget.automatic!.label}",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: chosen == null ? Icon(TablerIcons.check, color: primary) : null,
          onTap: () => _pick(null),
        ),
        const Divider(height: 1),
        // A manual pick isn't among the automatic sources; list it so it can be seen and re-picked.
        if (chosen != null && !(options.value ?? const []).any(isShown))
          ListTile(
            leading: const Icon(TablerIcons.hand_click),
            title: Text(chosen.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text("Picked manually · ${chosen.lyrics.lyrics?.length ?? 0} lines"),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LyricsSyncBadge(chosen.sync),
                const SizedBox(width: 8),
                Icon(TablerIcons.check, color: primary, size: 20),
              ],
            ),
          ),
        ...options.when(
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (e, _) => [
            const ListTile(leading: Icon(TablerIcons.alert_triangle), title: Text("Couldn't check the sources")),
          ],
          data: (list) => list.isEmpty
              ? [
                  const ListTile(
                    leading: Icon(TablerIcons.microphone_2_off),
                    title: Text("No source has lyrics for this track"),
                  ),
                ]
              : [
                  for (final option in list)
                    ListTile(
                      leading: Icon(_iconFor(option.origin)),
                      title: Text(option.label),
                      subtitle: Text(
                        "${option.origin.isOnlineDatabase ? "Online database" : option.origin.databaseName}"
                        " · ${option.lyrics.lyrics?.length ?? 0} lines",
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LyricsSyncBadge(option.sync),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 20,
                            child: chosen != null && isShown(option)
                                ? Icon(TablerIcons.check, color: primary, size: 20)
                                : null,
                          ),
                        ],
                      ),
                      onTap: () => _pick(option),
                    ),
                ],
        ),
        ListTile(
          leading: const Icon(TablerIcons.search),
          title: const Text("Search manually"),
          subtitle: const Text("Wrong or missing lyrics? Look them up on LRCLIB."),
          trailing: const Icon(TablerIcons.chevron_right),
          onTap: () => setState(() => _searching = true),
        ),
        if (shown != null && shown.sync != LyricsSync.plain) ...[
          const Divider(height: 1),
          _TimingSection(trackId: widget.item.id),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSearch(BuildContext context) {
    return Column(
      key: const ValueKey("search"),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 20, 8),
          child: Row(
            children: [
              IconButton(icon: const Icon(TablerIcons.arrow_left), onPressed: () => setState(() => _searching = false)),
              Text("Search lyrics", style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: TextField(
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: "Artist and title",
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(icon: const Icon(TablerIcons.search), onPressed: _search),
            ),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_results == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text("Search LRCLIB for lyrics")),
          )
        else if (_results!.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text("No results")),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _results!.length,
              itemBuilder: (context, index) {
                final match = _results![index];
                final duration = match.duration;
                return ListTile(
                  title: Text(match.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [
                      match.artist,
                      if (match.album != null && match.album!.isNotEmpty) match.album!,
                      if (duration != null)
                        "${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, "0")}",
                    ].join(" · "),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: LyricsSyncBadge(LyricsSync.of(match.lyrics)),
                  onTap: () => _pickMatch(match),
                );
              },
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  static IconData _iconFor(LyricsOrigin origin) => switch (origin) {
    LyricsOrigin.file => TablerIcons.file_music,
    LyricsOrigin.server => TablerIcons.server,
    LyricsOrigin.downloaded => TablerIcons.download,
    LyricsOrigin.lrclib || LyricsOrigin.amll || LyricsOrigin.netease => TablerIcons.world,
  };
}

/// Nudges lyrics that run ahead of or behind the music. Remembered per track.
class _TimingSection extends StatelessWidget {
  const _TimingSection({required this.trackId});

  final BaseItemId trackId;

  @override
  Widget build(BuildContext context) {
    final listenable = LyricsOffsetService.listenable(trackId);
    if (listenable == null) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: listenable,
      builder: (context, _, _) {
        final offset = LyricsOffsetService.offsetMs(trackId);
        final textTheme = Theme.of(context).textTheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text("Timing", style: textTheme.titleSmall),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Lyrics too early? Show them later. Remembered for this track.",
                  style: textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: offset <= -LyricsOffsetService.limit
                        ? null
                        : () {
                            FeedbackHelper.feedback(FeedbackType.selection);
                            LyricsOffsetService.nudge(trackId, -LyricsOffsetService.step);
                          },
                    icon: const Icon(TablerIcons.chevrons_left),
                    label: const Text("Earlier"),
                  ),
                  SizedBox(
                    width: 96,
                    child: Text(
                      LyricsOffsetService.format(offset),
                      textAlign: TextAlign.center,
                      style: textTheme.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: offset >= LyricsOffsetService.limit
                        ? null
                        : () {
                            FeedbackHelper.feedback(FeedbackType.selection);
                            LyricsOffsetService.nudge(trackId, LyricsOffsetService.step);
                          },
                    icon: const Icon(TablerIcons.chevrons_right),
                    label: const Text("Later"),
                  ),
                ],
              ),
              TextButton(
                onPressed: offset == 0 ? null : () => LyricsOffsetService.reset(trackId),
                child: const Text("Reset"),
              ),
            ],
          ),
        );
      },
    );
  }
}
