import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/match/acoustid.dart';
import 'package:diapason/services/tag_editor/match/musicbrainz.dart';
import 'package:diapason/services/tag_editor/tag_matcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:logging/logging.dart';

final _log = Logger("TagMatchDialog");

/// MusicBrainz matching: recordings for a single track (plus AcoustID on
/// desktop), releases for an album. Pops with a confirmation message once
/// values were applied to the session (nothing is saved here).
class TagMatchDialog extends StatefulWidget {
  const TagMatchDialog({super.key, required this.matcher});

  final TagMatcher matcher;

  @override
  State<TagMatchDialog> createState() => _TagMatchDialogState();
}

class _TagMatchDialogState extends State<TagMatchDialog> {
  late final bool _album = widget.matcher.session.isAlbum;
  late final TextEditingController _primary;
  late final TextEditingController _artist;
  late final TextEditingController _acoustIdKey;
  List<Object>? _results;
  bool _busy = false;
  String? _error;
  bool _includeGenres = false;
  AcoustIdAvailability? _acoustId;

  AudioTags get _tags => widget.matcher.session.albumEdited ?? widget.matcher.session.edited.first;

  @override
  void initState() {
    super.initState();
    final first = widget.matcher.session.edited.first;
    _primary = TextEditingController(
      text: _album ? _tags[TagField.album] ?? first[TagField.album] : first[TagField.title],
    );
    _artist = TextEditingController(
      text: (_album ? _tags.all(TagField.albumArtists).firstOrNull : null) ?? first.all(TagField.artists).firstOrNull,
    );
    _acoustIdKey = TextEditingController(text: FinampSettingsHelper.finampSettings.tagEditorAcoustIdApiKey);
    if (!_album) _checkAcoustId();
    _search();
  }

  @override
  void dispose() {
    _primary.dispose();
    _artist.dispose();
    _acoustIdKey.dispose();
    super.dispose();
  }

  Future<void> _checkAcoustId() async {
    final availability = widget.matcher.session.tracks.first.localFile == null
        ? null
        : await widget.matcher.acoustId.availability(_acoustIdKey.text);
    if (mounted) setState(() => _acoustId = availability);
  }

  Future<void> _run(Future<List<Object>> Function() search) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await search();
      if (mounted) setState(() => _results = results);
    } catch (e, st) {
      final message = FriendlyError.report(_log, "MusicBrainz search", e, st);
      if (mounted) setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _search() => _run(
    () async => _album
        ? await widget.matcher.searchReleases(album: _primary.text, artist: _artist.text)
        : await widget.matcher.searchRecordings(0, title: _primary.text, artist: _artist.text),
  );

  Future<void> _fingerprint() async {
    FinampSetters.setTagEditorAcoustIdApiKey(_acoustIdKey.text.trim());
    await _run(() => widget.matcher.fingerprint(0, _acoustIdKey.text));
  }

  Future<void> _apply(Object candidate) async {
    final l = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      String message;
      if (candidate is MbReleaseCandidate) {
        final matched = await widget.matcher.applyRelease(candidate, includeGenres: _includeGenres);
        message = l.tagEditorMatchAppliedTracks(matched ?? 0, widget.matcher.session.tracks.length);
      } else {
        await widget.matcher.applyRecording(0, candidate as MbRecordingCandidate, includeGenres: _includeGenres);
        message = l.tagEditorMatchApplied;
      }
      if (mounted) Navigator.pop(context, message);
    } catch (e, st) {
      final message = FriendlyError.report(_log, "Applying a MusicBrainz match", e, st);
      if (mounted) {
        setState(() {
          _busy = false;
          _error = message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l.tagEditorMatchTitle),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 640,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _primary,
                    decoration: InputDecoration(
                      labelText: _album ? l.tagEditorFieldAlbum : l.tagEditorFieldTitle,
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _artist,
                    decoration: InputDecoration(
                      labelText: _album ? l.tagEditorFieldAlbumArtists : l.tagEditorFieldArtists,
                      isDense: true,
                    ),
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
            if (!_album) _acoustIdRow(l, theme),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l.tagEditorMatchIncludeGenres),
              value: _includeGenres,
              onChanged: (v) => setState(() => _includeGenres = v),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            Expanded(
              child: _results == null
                  ? const SizedBox.shrink()
                  : _results!.isEmpty
                  ? Center(child: Text(l.tagEditorMatchNoResults))
                  : ListView.builder(
                      itemCount: _results!.length,
                      itemBuilder: (context, i) => _resultTile(l, theme, _results![i]),
                    ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.tagEditorCancel))],
    );
  }

  Widget _acoustIdRow(AppLocalizations l, ThemeData theme) {
    final availability = _acoustId;
    final note = switch (availability) {
      null => widget.matcher.session.tracks.first.localFile == null ? l.tagEditorAcoustIdNotLocal : null,
      AcoustIdAvailability.notDesktop => l.tagEditorAcoustIdNotDesktop,
      AcoustIdAvailability.noFpcalc => l.tagEditorAcoustIdNoFpcalc,
      AcoustIdAvailability.noApiKey || AcoustIdAvailability.available => null,
    };
    if (note != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(note, style: theme.textTheme.bodySmall),
      );
    }
    if (availability == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _acoustIdKey,
              decoration: InputDecoration(
                labelText: l.tagEditorAcoustIdKeyLabel,
                helperText: availability == AcoustIdAvailability.noApiKey ? l.tagEditorAcoustIdNoKey : null,
                helperMaxLines: 2,
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _busy || _acoustIdKey.text.trim().isEmpty ? null : _fingerprint,
            icon: const Icon(TablerIcons.fingerprint),
            label: Text(l.tagEditorAcoustId),
          ),
        ],
      ),
    );
  }

  static String _duration(Duration? d) {
    if (d == null) return "";
    return "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, "0")}";
  }

  Widget _resultTile(AppLocalizations l, ThemeData theme, Object r) {
    final (title, subtitle, confidence) = switch (r) {
      MbRecordingCandidate c => (
        c.title,
        [
          MbArtistCredit.display(c.artists),
          c.bestRelease?.title,
          c.bestRelease?.date,
          _duration(c.length),
        ].where((s) => s != null && s.isNotEmpty).join(" · "),
        c.confidence,
      ),
      MbReleaseCandidate c => (
        c.title,
        [
          MbArtistCredit.display(c.artists),
          c.date,
          c.country,
          c.format,
          if (c.trackCount != null) l.tagEditorMatchTracks(c.trackCount!),
        ].where((s) => s != null && s.isNotEmpty).join(" · "),
        c.confidence,
      ),
      _ => ("", "", 0.0),
    };
    final color = confidence >= 0.85
        ? Colors.green
        : confidence >= 0.6
        ? Colors.orange
        : theme.colorScheme.error;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      leading: Container(
        width: 52,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
        child: Text(
          l.tagEditorMatchConfidence((confidence * 100).round()),
          textAlign: TextAlign.center,
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      ),
      trailing: const Icon(TablerIcons.chevron_right),
      enabled: !_busy,
      onTap: () => _apply(r),
    );
  }
}
