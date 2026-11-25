import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/components/lyrics/lyrics_export_sheet.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/lyrics/furigana.dart';
import 'package:diapason/services/lyrics/japanese_dictionary.dart';
import 'package:diapason/services/lyrics/lyrics_extras.dart';
import 'package:diapason/services/lyrics/lyrics_translation.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/feedback_helper.dart';
import 'package:diapason/services/lyrics/lrclib_client.dart';
import 'package:diapason/services/lyrics/lyrics_offset_service.dart';
import 'package:diapason/services/lyrics/lyrics_sources.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _log = Logger("LyricsManager");

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

  /// Label the button AppLocalizations.of(context)!.lyricsOptions even without a timing shift to show (used where there is no lyrics view).
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
            ? Text(AppLocalizations.of(context)!.lyricsOptions)
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
  return showAdaptiveModalSheet<void>(
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
          child: Text(AppLocalizations.of(context)!.lyricsTitle, style: Theme.of(context).textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text(AppLocalizations.of(context)!.lyricsSource, style: Theme.of(context).textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            AppLocalizations.of(context)!.lyricsYourLibraryThen(databases),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        ListTile(
          leading: const Icon(TablerIcons.wand),
          title: Text(AppLocalizations.of(context)!.lyricsAutomatic),
          subtitle: Text(
            widget.automatic == null
                ? AppLocalizations.of(context)!.lyricsBestAvailable
                : AppLocalizations.of(context)!.lyricsBestAvailableNow(widget.automatic!.label),
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
            subtitle: Text(AppLocalizations.of(context)!.lyricsPickedManually(chosen.lyrics.lyrics?.length ?? 0)),
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
            ListTile(
              leading: Icon(TablerIcons.alert_triangle),
              title: Text(AppLocalizations.of(context)!.lyricsCheckFailed),
            ),
          ],
          data: (list) => list.isEmpty
              ? [
                  ListTile(
                    leading: Icon(TablerIcons.microphone_2_off),
                    title: Text(AppLocalizations.of(context)!.lyricsNoSource),
                  ),
                ]
              : [
                  for (final option in list)
                    ListTile(
                      leading: Icon(_iconFor(option.origin)),
                      title: Text(option.label),
                      subtitle: Text(
                        AppLocalizations.of(context)!.lyricsSourceLines(
                          option.origin.isOnlineDatabase
                              ? AppLocalizations.of(context)!.lyricsOnlineDatabase
                              : option.origin.databaseName,
                          option.lyrics.lyrics?.length ?? 0,
                        ),
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
          title: Text(AppLocalizations.of(context)!.lyricsSearchManually),
          subtitle: Text(AppLocalizations.of(context)!.lyricsSearchManuallySubtitle),
          trailing: const Icon(TablerIcons.chevron_right),
          onTap: () => setState(() => _searching = true),
        ),
        if (shown != null && shown.sync != LyricsSync.plain) ...[
          const Divider(height: 1),
          _TimingSection(trackId: widget.item.id),
        ],
        if (shown?.lyrics.lyrics case final lines? when lines.isNotEmpty) ...[
          const Divider(height: 1),
          _ExtrasSection(item: widget.item, lines: lines),
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
              Text(AppLocalizations.of(context)!.lyricsSearchTitle, style: Theme.of(context).textTheme.titleLarge),
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
              hintText: AppLocalizations.of(context)!.lyricsSearchHint,
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
          Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text(AppLocalizations.of(context)!.lyricsSearchPrompt)),
          )
        else if (_results!.isEmpty)
          Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text(AppLocalizations.of(context)!.lyricsNoResults)),
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
    LyricsOrigin.plugin => TablerIcons.plug,
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
                child: Text(AppLocalizations.of(context)!.lyricsTiming, style: textTheme.titleSmall),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(AppLocalizations.of(context)!.lyricsTimingHint, style: textTheme.bodySmall),
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
                    label: Text(AppLocalizations.of(context)!.lyricsEarlier),
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
                    label: Text(AppLocalizations.of(context)!.lyricsLater),
                  ),
                ],
              ),
              TextButton(
                onPressed: offset == 0 ? null : () => LyricsOffsetService.reset(trackId),
                child: Text(AppLocalizations.of(context)!.lyricsReset),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Per-song translation toggle, a nudge to get the Japanese dictionary, and export.
class _ExtrasSection extends ConsumerWidget {
  const _ExtrasSection({required this.item, required this.lines});

  final BaseItemDto item;
  final List<LyricLine> lines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final translationOn = ref.watch(finampSettingsProvider.lyricsTranslationEnabled);
    final config = ref.watch(lyricsTranslationConfigProvider);
    final hidden = ref.watch(lyricsTranslationHiddenProvider(item.id.raw));
    final wantsJapanese =
        ref.watch(finampSettingsProvider.lyricsFurigana) || ref.watch(finampSettingsProvider.lyricsRomaji);
    final dictionary = ref.watch(japaneseDictionaryProvider);
    final japanese = wantsJapanese && Furigana.isJapaneseSong(lines.map((l) => l.text));

    String? translationStatus() {
      if (!config.isUsable) return l10n.lyricsTranslationNotSetUp;
      if (hidden) return null;
      final translation = ref.watch(
        lyricsTranslationProvider((
          trackId: item.id.raw,
          lines: lines,
          target: lyricsTranslationTarget(context, config),
        )),
      );
      return translation.when(
        loading: () => l10n.lyricsTranslationLoading,
        error: (e, _) => l10n.lyricsTranslationFailed(lyricsTranslationErrorMessage(e)),
        data: (t) => t == null
            ? null
            : t.sameLanguage
            ? l10n.lyricsTranslationSameLanguage
            : t.sourceLanguage == null
            ? null
            : l10n.lyricsTranslationFrom(t.sourceLanguage!),
      );
    }

    final status = translationOn ? translationStatus() : null;
    return Column(
      children: [
        if (translationOn)
          SwitchListTile.adaptive(
            secondary: const Icon(TablerIcons.language),
            title: Text(l10n.lyricsShowTranslation),
            subtitle: status == null ? null : Text(status),
            value: !hidden && config.isUsable,
            onChanged: config.isUsable
                ? (value) => LyricsTranslationService.instance.setHidden(item.id.raw, !value)
                : null,
          ),
        if (japanese &&
            (dictionary.status == JapaneseDictionaryStatus.missing ||
                dictionary.status == JapaneseDictionaryStatus.failed ||
                dictionary.status == JapaneseDictionaryStatus.downloading))
          ListTile(
            leading: const Icon(TablerIcons.language_hiragana),
            title: Text(l10n.lyricsDictionaryNeeded(JapaneseDictionary.sizeLabel)),
            subtitle: dictionary.status == JapaneseDictionaryStatus.downloading
                ? LinearProgressIndicator(value: dictionary.progress)
                : dictionary.error == null
                ? null
                : Text(l10n.lyricsDictionaryFailed(dictionary.error!)),
            trailing: dictionary.status == JapaneseDictionaryStatus.downloading
                ? null
                : TextButton(
                    onPressed: () => downloadJapaneseDictionary(context),
                    child: Text(l10n.lyricsDictionaryDownload),
                  ),
          ),
        ListTile(
          leading: const Icon(TablerIcons.file_export),
          title: Text(l10n.lyricsExport),
          subtitle: Text(l10n.lyricsExportSubtitle),
          trailing: const Icon(TablerIcons.chevron_right),
          onTap: () => showLyricsExport(context, item: item, lines: lines),
        ),
      ],
    );
  }
}

/// Downloads the Japanese dictionary, reporting a failure in a snackbar.
Future<void> downloadJapaneseDictionary(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = AppLocalizations.of(context)!;
  try {
    await JapaneseDictionary.instance.download();
  } catch (e, stack) {
    final message = FriendlyError.report(_log, "Japanese dictionary download", e, stack);
    messenger?.showSnackBar(SnackBar(content: Text(l10n.lyricsDictionaryFailed(message))));
  }
}
