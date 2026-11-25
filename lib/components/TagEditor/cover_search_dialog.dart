import 'dart:typed_data';

import 'package:diapason/components/TagEditor/tag_editor_page.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/match/cover_search.dart';
import 'package:diapason/services/tag_editor/tag_matcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:logging/logging.dart';

final _log = Logger("CoverSearchDialog");

/// Grid of covers from Cover Art Archive, iTunes and Deezer. Tapping one
/// downloads the full image for a preview with its real resolution; pops
/// with the chosen bytes.
class CoverSearchDialog extends StatefulWidget {
  const CoverSearchDialog({super.key, required this.matcher});

  final TagMatcher matcher;

  @override
  State<CoverSearchDialog> createState() => _CoverSearchDialogState();
}

class _CoverSearchDialogState extends State<CoverSearchDialog> {
  late final TextEditingController _album;
  late final TextEditingController _artist;
  List<CoverCandidate>? _results;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final session = widget.matcher.session;
    final tags = session.albumEdited ?? (session.edited.isEmpty ? AudioTags() : session.edited.first);
    final first = session.edited.isEmpty ? AudioTags() : session.edited.first;
    _album = TextEditingController(text: tags[TagField.album] ?? first[TagField.album]);
    _artist = TextEditingController(
      text: tags.all(TagField.albumArtists).firstOrNull ?? first.all(TagField.artists).firstOrNull,
    );
    _search();
  }

  @override
  void dispose() {
    _album.dispose();
    _artist.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _busy = true);
    final results = await widget.matcher.searchCovers(album: _album.text, artist: _artist.text);
    if (mounted) {
      setState(() {
        _results = results;
        _busy = false;
      });
    }
  }

  Future<void> _preview(CoverCandidate candidate) async {
    final bytes = await showDialog<Uint8List>(
      context: context,
      builder: (_) => _CoverPreviewDialog(matcher: widget.matcher, candidate: candidate),
    );
    if (bytes != null && mounted) Navigator.pop(context, bytes);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l.tagEditorCoverSearchTitle),
      content: SizedBox(
        width: 720,
        height: 560,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _album,
                    decoration: InputDecoration(labelText: l.tagEditorFieldAlbum, isDense: true),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _artist,
                    decoration: InputDecoration(labelText: l.tagEditorFieldAlbumArtists, isDense: true),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                IconButton(
                  tooltip: l.tagEditorMatchSearch,
                  onPressed: _busy ? null : _search,
                  icon: const Icon(TablerIcons.search),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: _results == null
                  ? const SizedBox.shrink()
                  : _results!.isEmpty
                  ? Center(child: Text(l.tagEditorCoversNone))
                  : GridView.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.72,
                      ),
                      itemCount: _results!.length,
                      itemBuilder: (context, i) {
                        final c = _results![i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _preview(c),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    c.thumbnailUrl.toString(),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Center(child: Icon(TablerIcons.photo_off)),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                [c.title, c.artist].nonNulls.join(" · "),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                              Text(
                                [
                                  c.source.label,
                                  if (c.nominalSize != null) l.tagEditorCoverNominalSize(c.nominalSize!),
                                ].join(" · "),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.tagEditorCancel))],
    );
  }
}

class _CoverPreviewDialog extends StatefulWidget {
  const _CoverPreviewDialog({required this.matcher, required this.candidate});

  final TagMatcher matcher;
  final CoverCandidate candidate;

  @override
  State<_CoverPreviewDialog> createState() => _CoverPreviewDialogState();
}

class _CoverPreviewDialogState extends State<_CoverPreviewDialog> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _download();
  }

  Future<void> _download() async {
    try {
      final bytes = await widget.matcher.download(widget.candidate.imageUrl);
      if (mounted) setState(() => _bytes = bytes);
    } catch (e, st) {
      final message = FriendlyError.report(_log, "Downloading a cover", e, st);
      if (mounted) setState(() => _error = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final bytes = _bytes;
    return AlertDialog(
      title: Text(widget.candidate.source.label),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: bytes != null
                  ? Image.memory(bytes, fit: BoxFit.contain)
                  : _error != null
                  ? Center(child: Text(_error!))
                  : const Center(child: CircularProgressIndicator()),
            ),
            const SizedBox(height: 8),
            if (bytes != null) ImageSizeLabel(bytes: bytes),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.tagEditorCancel)),
        FilledButton(
          onPressed: bytes == null ? null : () => Navigator.pop(context, bytes),
          child: Text(l.tagEditorCoverUse),
        ),
      ],
    );
  }
}
