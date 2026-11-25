import 'package:diapason/utils/platform.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:diapason/components/TagEditor/cover_search_dialog.dart';
import 'package:diapason/components/TagEditor/tag_match_dialog.dart';
import 'package:diapason/components/MusicScreen/music_screen_tab_view.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/tag_edit_session.dart';
import 'package:diapason/services/tag_editor/tag_edit_target.dart';
import 'package:diapason/services/tag_editor/tag_matcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:logging/logging.dart';

final _log = Logger("TagEditorPage");

bool get _isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Opens the editor: a dialog on desktop, a full screen on mobile.
Future<void> showTagEditor(NavigatorState navigator, BaseItemDto item) {
  if (_isDesktop) {
    return navigator.push(
      DialogRoute<void>(
        context: navigator.context,
        barrierDismissible: false,
        builder: (context) => Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820, maxHeight: 900),
            child: TagEditorPage(item: item),
          ),
        ),
      ),
    );
  }
  return navigator.push(MaterialPageRoute<void>(builder: (_) => TagEditorPage(item: item)));
}

String tagFieldLabel(AppLocalizations l, TagField f) => switch (f) {
  TagField.title => l.tagEditorFieldTitle,
  TagField.artists => l.tagEditorFieldArtists,
  TagField.albumArtists => l.tagEditorFieldAlbumArtists,
  TagField.album => l.tagEditorFieldAlbum,
  TagField.trackNumber => l.tagEditorFieldTrackNumber,
  TagField.trackTotal => l.tagEditorFieldTrackTotal,
  TagField.discNumber => l.tagEditorFieldDiscNumber,
  TagField.discTotal => l.tagEditorFieldDiscTotal,
  TagField.date => l.tagEditorFieldDate,
  TagField.genres => l.tagEditorFieldGenres,
  TagField.composers => l.tagEditorFieldComposers,
  TagField.comment => l.tagEditorFieldComment,
  TagField.lyrics => l.tagEditorFieldLyrics,
  TagField.musicBrainzRecordingId => l.tagEditorFieldMbRecording,
  TagField.musicBrainzReleaseTrackId => l.tagEditorFieldMbReleaseTrack,
  TagField.musicBrainzReleaseId => l.tagEditorFieldMbRelease,
  TagField.musicBrainzReleaseGroupId => l.tagEditorFieldMbReleaseGroup,
  TagField.musicBrainzArtistIds => l.tagEditorFieldMbArtists,
  TagField.musicBrainzAlbumArtistIds => l.tagEditorFieldMbAlbumArtists,
  TagField.replayGainTrackGain => l.tagEditorFieldRgTrackGain,
  TagField.replayGainTrackPeak => l.tagEditorFieldRgTrackPeak,
  TagField.replayGainAlbumGain => l.tagEditorFieldRgAlbumGain,
  TagField.replayGainAlbumPeak => l.tagEditorFieldRgAlbumPeak,
};

class TagEditorPage extends StatefulWidget {
  const TagEditorPage({super.key, required this.item, this.sessionLoader});

  final BaseItemDto item;

  /// Injectable for tests.
  final Future<TagEditSession> Function(BaseItemDto item)? sessionLoader;

  @override
  State<TagEditorPage> createState() => _TagEditorPageState();
}

class _TagEditorPageState extends State<TagEditorPage> {
  TagEditSession? _session;
  TagMatcher? _matcher;
  Object? _error;
  bool _saving = false;

  /// Bumped when values change from outside the text fields (load, match),
  /// so the fields are rebuilt with the new text.
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final session = await (widget.sessionLoader ?? TagEditSession.open)(widget.item);
      if (!mounted) return;
      setState(() {
        _session = session..addListener(_onSessionChanged);
        _matcher = TagMatcher(session);
      });
    } catch (e, st) {
      FriendlyError.report(_log, "Opening the tag editor", e, st);
      if (mounted) setState(() => _error = e);
    }
  }

  void _onSessionChanged() => setState(() {});

  void _externalChange() => setState(() => _revision++);

  @override
  void dispose() {
    _session?.removeListener(_onSessionChanged);
    super.dispose();
  }

  Future<void> _save() async {
    final session = _session!;
    final l = AppLocalizations.of(context)!;
    setState(() => _saving = true);
    final errors = await session.save();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _revision++;
    });
    musicScreenRefreshStream.add(null);
    if (errors.isEmpty) {
      GlobalSnackbar.message((_) => l.tagEditorSaved, isConfirmation: true);
    } else {
      final message = FriendlyError.report(_log, "Saving tags", errors.values.first);
      GlobalSnackbar.message((_) => l.tagEditorSaveFailed(errors.length, message));
    }
  }

  Future<void> _match() async {
    final applied = await showDialog<String>(
      context: context,
      builder: (_) => TagMatchDialog(matcher: _matcher!),
    );
    if (applied != null) {
      _externalChange();
      GlobalSnackbar.message((_) => applied);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!(_session?.hasChanges ?? false)) return true;
    final l = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.tagEditorDiscardTitle),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.tagEditorCancel)),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.tagEditorDiscard)),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final session = _session;
    final isAlbum = widget.item.type == "MusicAlbum";
    return PopScope(
      canPop: !(session?.hasChanges ?? false),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          session?.removeListener(_onSessionChanged);
          _session = null;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(icon: const Icon(TablerIcons.x), onPressed: () => Navigator.of(context).maybePop()),
          title: Text(isAlbum ? l.tagEditorAlbumTitle : l.tagEditorTitle),
          actions: [
            if (session != null && session.canEditAnything && session.tracks.isNotEmpty) ...[
              TextButton.icon(
                onPressed: _saving ? null : _match,
                icon: const Icon(TablerIcons.wand),
                label: Text(l.tagEditorMatch),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _saving || !session.hasChanges ? null : _save,
                child: _saving
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l.tagEditorSave),
              ),
              const SizedBox(width: 12),
            ],
          ],
        ),
        body: switch ((session, _error)) {
          (_, final Object error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l.tagEditorLoadFailed(FriendlyError.message(error)), textAlign: TextAlign.center),
            ),
          ),
          (null, _) => const Center(child: CircularProgressIndicator()),
          (final TagEditSession s, _) => TagEditorForm(
            session: s,
            matcher: _matcher!,
            revision: _revision,
            onExternalChange: _externalChange,
          ),
        },
      ),
    );
  }
}

class TagEditorForm extends StatelessWidget {
  const TagEditorForm({
    super.key,
    required this.session,
    required this.matcher,
    required this.revision,
    required this.onExternalChange,
  });

  final TagEditSession session;
  final TagMatcher matcher;
  final int revision;
  final VoidCallback onExternalChange;

  static const _main = [
    TagField.title,
    TagField.artists,
    TagField.albumArtists,
    TagField.album,
    TagField.trackNumber,
    TagField.discNumber,
    TagField.date,
    TagField.genres,
    TagField.composers,
    TagField.comment,
    TagField.lyrics,
  ];

  static const _pairs = {TagField.trackNumber: TagField.trackTotal, TagField.discNumber: TagField.discTotal};

  bool _visible(TagField f) {
    if (session.isAlbum && f.isPerTrack) return false;
    // Hide what this source can neither store nor show.
    return session.canEdit(f) || (session.shared(f)?.isNotEmpty ?? true);
  }

  Widget _field(TagField f) => _TagTextField(key: ValueKey("${f.name}-$revision"), session: session, field: f);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    List<Widget> fields(Iterable<TagField> list) => [
      for (final f in list)
        if (_pairs.containsKey(f))
          if (_visible(f) || _visible(_pairs[f]!))
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_visible(f)) Expanded(child: _field(f)),
                if (_visible(f) && _visible(_pairs[f]!)) const SizedBox(width: 12),
                if (_visible(_pairs[f]!)) Expanded(child: _field(_pairs[f]!)),
              ],
            )
          else
            const SizedBox.shrink()
        else if (_visible(f))
          _field(f),
    ];

    final mb = TagField.values.where((f) => f.isMusicBrainz && _visible(f)).toList();
    final rg = TagField.values.where((f) => f.isReplayGain && _visible(f)).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _Banner(session: session),
        const SizedBox(height: 12),
        _CoverSection(session: session, matcher: matcher),
        const SizedBox(height: 16),
        Text(l.tagEditorSectionTags, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        ...fields(_main),
        if (session.isAlbum && session.tracks.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(l.tagEditorSectionTracks, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (var i = 0; i < session.tracks.length; i++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  child: _TagTextField(
                    key: ValueKey("track-$i-number-$revision"),
                    session: session,
                    field: TagField.trackNumber,
                    track: i,
                    label: l.tagEditorTrackNumberShort,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TagTextField(
                    key: ValueKey("track-$i-title-$revision"),
                    session: session,
                    field: TagField.title,
                    track: i,
                  ),
                ),
              ],
            ),
        ],
        if (mb.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(l.tagEditorSectionMusicBrainz),
            children: [for (final f in mb) _field(f)],
          ),
        if (rg.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(l.tagEditorSectionReplayGain),
            children: [for (final f in rg) _field(f)],
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.session});

  final TagEditSession session;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final reason = session.readOnlyReason;
    final readOnly = !session.canEditAnything;
    final text = reason != null
        ? switch (reason) {
            TagReadOnlyReason.subsonic => l.tagEditorReadOnlySubsonic,
            TagReadOnlyReason.mpd => l.tagEditorReadOnlyMpd,
            TagReadOnlyReason.youtube => l.tagEditorReadOnlyYoutube,
            TagReadOnlyReason.unsupportedFile => l.tagEditorReadOnlyUnsupportedFile,
            TagReadOnlyReason.missingFile => l.tagEditorReadOnlyMissingFile,
            TagReadOnlyReason.notLoaded => l.tagEditorReadOnlyNotLoaded,
          }
        : switch (session.storage) {
            TagStorage.file => l.tagEditorStorageFile,
            TagStorage.jellyfin => l.tagEditorStorageJellyfin,
            TagStorage.plex => l.tagEditorStoragePlex,
            TagStorage.none => l.tagEditorReadOnlyNotLoaded,
          };
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: readOnly || reason != null ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            readOnly || reason != null ? TablerIcons.lock : TablerIcons.info_circle,
            color: readOnly || reason != null ? scheme.onErrorContainer : scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: readOnly || reason != null ? scheme.onErrorContainer : scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TagTextField extends StatelessWidget {
  const _TagTextField({super.key, required this.session, required this.field, this.track, this.label});

  final TagEditSession session;
  final TagField field;
  final int? track;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final values = track == null ? session.shared(field) : session.edited[track!].all(field);
    final enabled = session.canEdit(field, track: track);
    final multiline = field == TagField.lyrics || field == TagField.comment;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        initialValue: values?.join(field.isMultiValue ? "; " : ""),
        enabled: enabled,
        keyboardType: field.isNumeric
            ? TextInputType.number
            : (multiline ? TextInputType.multiline : TextInputType.text),
        minLines: field == TagField.lyrics ? 3 : 1,
        maxLines: multiline ? 12 : 1,
        decoration: InputDecoration(
          labelText: label ?? tagFieldLabel(l, field),
          hintText: values == null ? l.tagEditorMultipleValues : null,
          helperText: !enabled
              ? l.tagEditorNotEditable
              : (field.isMultiValue && track == null ? l.tagEditorMultiValueHelper : null),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (text) {
          final parsed = field.isMultiValue ? text.split(";") : [text];
          if (track == null) {
            session.setShared(field, parsed);
          } else {
            session.setTrack(track!, field, parsed);
          }
        },
      ),
    );
  }
}

class _CoverSection extends StatelessWidget {
  const _CoverSection({required this.session, required this.matcher});

  final TagEditSession session;
  final TagMatcher matcher;

  Future<void> _fromFile() async {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty) return;
    try {
      session.setCover(CoverReplaced(await picked.first.xFile.readAsBytes()));
    } catch (e, st) {
      final message = FriendlyError.report(_log, "Reading a cover file", e, st);
      GlobalSnackbar.message((_) => message);
    }
  }

  Future<void> _fromUrl(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.tagEditorCoverFromUrl),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: l.tagEditorCoverUrlHint),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l.tagEditorCancel)),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(l.tagEditorCoverDownload)),
        ],
      ),
    );
    final uri = Uri.tryParse(url?.trim() ?? "");
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith("http")) return;
    try {
      session.setCover(CoverReplaced(await matcher.download(uri)));
    } catch (e, st) {
      final message = FriendlyError.report(_log, "Downloading a cover", e, st);
      GlobalSnackbar.message((_) => message);
    }
  }

  Future<void> _search(BuildContext context) async {
    final bytes = await showDialog<Uint8List>(
      context: context,
      builder: (_) => CoverSearchDialog(matcher: matcher),
    );
    if (bytes != null) session.setCover(CoverReplaced(bytes));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final embedded = session.embeddedCover;
    final serverUrl = session.serverCoverUrl;
    final placeholder = Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(TablerIcons.photo_off, size: 40)),
    );
    final Widget image = switch (session.cover) {
      CoverRemoved() => placeholder,
      _ when embedded != null => Image.memory(embedded.data, fit: BoxFit.cover),
      _ when serverUrl != null => Image.network(
        serverUrl.toString(),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
      _ => placeholder,
    };
    final status = switch (session.cover) {
      CoverReplaced() => l.tagEditorCoverPending,
      CoverRemoved() => l.tagEditorCoverWillBeRemoved,
      CoverUnchanged() when embedded == null && serverUrl == null => l.tagEditorCoverNone,
      CoverUnchanged() => null,
    };

    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox.square(dimension: 140, child: image),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.tagEditorSectionCover, style: Theme.of(context).textTheme.titleMedium),
            if (embedded != null && session.cover is! CoverRemoved) ImageSizeLabel(bytes: embedded.data),
            if (status != null) Text(status, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (session.canReplaceCover)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _fromFile,
                    icon: const Icon(TablerIcons.file_upload),
                    label: Text(l.tagEditorCoverFromFile),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _fromUrl(context),
                    icon: const Icon(TablerIcons.link),
                    label: Text(l.tagEditorCoverFromUrl),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _search(context),
                    icon: const Icon(TablerIcons.photo_search),
                    label: Text(l.tagEditorCoverSearch),
                  ),
                  if (session.canRemoveCover)
                    OutlinedButton.icon(
                      onPressed: () => session.setCover(const CoverRemoved()),
                      icon: const Icon(TablerIcons.trash),
                      label: Text(l.tagEditorCoverRemove),
                    ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Decodes [bytes] once to show the real pixel size.
class ImageSizeLabel extends StatelessWidget {
  const ImageSizeLabel({super.key, required this.bytes});

  final Uint8List bytes;

  static final _cache = Expando<Future<(int, int)?>>();

  static Future<(int, int)?> _size(Uint8List bytes) => _cache[bytes] ??= () async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = (descriptor.width, descriptor.height);
      descriptor.dispose();
      buffer.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return FutureBuilder<(int, int)?>(
      future: _size(bytes),
      builder: (context, snapshot) {
        final size = snapshot.data;
        if (size == null) return const SizedBox.shrink();
        return Text(l.tagEditorCoverResolution(size.$1, size.$2), style: Theme.of(context).textTheme.bodySmall);
      },
    );
  }
}
