import 'package:diapason/models/jellyfin_models.dart';
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

/// Shows where the lyrics on screen come from and how synced they are; tapping it lists every source that has
/// lyrics for the track, to pick another.
class LyricsSourceChip extends ConsumerWidget {
  const LyricsSourceChip({super.key, required this.item, required this.automatic, required this.shown});

  final BaseItemDto item;

  /// What was picked automatically.
  final LyricsOption? automatic;

  /// What is on screen (the user's pick, or [automatic]).
  final LyricsOption? shown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.75);
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showLyricsSourcePicker(context, item: item, automatic: automatic, shown: shown),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (shown != null) ...[
                LyricsSyncBadge(shown!.sync, dense: true),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    shown!.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ),
              ] else
                Text("Find lyrics", style: TextStyle(fontSize: 12, color: color)),
              const SizedBox(width: 2),
              Icon(TablerIcons.chevron_down, size: 14, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showLyricsSourcePicker(
  BuildContext context, {
  required BaseItemDto item,
  required LyricsOption? automatic,
  required LyricsOption? shown,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (context) => _LyricsSourcePicker(item: item, automatic: automatic, shown: shown),
  );
}

class _LyricsSourcePicker extends ConsumerWidget {
  const _LyricsSourcePicker({required this.item, required this.automatic, required this.shown});

  final BaseItemDto item;
  final LyricsOption? automatic;
  final LyricsOption? shown;

  Future<void> _pick(BuildContext context, WidgetRef ref, LyricsOption? option) async {
    ref.read(chosenLyricsProvider(item.id).notifier).state = option;
    await GetIt.instance<LyricsSources>().choices.choose(item.id, option?.origin);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(lyricsOptionsProvider((item, automatic)));
    final chosen = ref.watch(chosenLyricsProvider(item.id));
    final databases = LyricsSources.enabledDatabases.map((o) => o.databaseName).join(", ");

    bool isShown(LyricsOption option) =>
        shown != null && option.origin == shown!.origin && option.label == shown!.label;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text("Lyrics source", style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text("Your library, then $databases.", style: Theme.of(context).textTheme.bodySmall),
          ),
          ListTile(
            leading: const Icon(TablerIcons.wand),
            title: const Text("Automatic"),
            subtitle: Text(
              automatic == null ? "Best available" : "Best available · now ${automatic!.label}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: chosen == null ? Icon(TablerIcons.check, color: Theme.of(context).colorScheme.primary) : null,
            onTap: () => _pick(context, ref, null),
          ),
          const Divider(height: 1),
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
                                  ? Icon(TablerIcons.check, color: Theme.of(context).colorScheme.primary, size: 20)
                                  : null,
                            ),
                          ],
                        ),
                        onTap: () => _pick(context, ref, option),
                      ),
                  ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  static IconData _iconFor(LyricsOrigin origin) => switch (origin) {
    LyricsOrigin.file => TablerIcons.file_music,
    LyricsOrigin.server => TablerIcons.server,
    LyricsOrigin.downloaded => TablerIcons.download,
    LyricsOrigin.lrclib || LyricsOrigin.amll || LyricsOrigin.netease => TablerIcons.world,
  };
}
