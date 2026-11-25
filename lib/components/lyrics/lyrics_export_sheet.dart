import 'package:diapason/screens/desktop/desktop_router.dart';
import 'dart:convert';
import 'dart:io';

import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/lyrics/lyrics_exporter.dart';
import 'package:diapason/services/lyrics/lyrics_offset_service.dart';
import 'package:diapason/utils/platform_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

final _log = Logger("LyricsExport");

/// Picks a format, then shares (phones), saves (desktop) or copies the lyrics. The track's timing offset is baked in.
Future<void> showLyricsExport(BuildContext context, {required BaseItemDto item, required List<LyricLine> lines}) {
  return showAdaptiveModalSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => _LyricsExportSheet(item: item, lines: lines),
  );
}

class _LyricsExportSheet extends StatefulWidget {
  const _LyricsExportSheet({required this.item, required this.lines});

  final BaseItemDto item;
  final List<LyricLine> lines;

  @override
  State<_LyricsExportSheet> createState() => _LyricsExportSheetState();
}

class _LyricsExportSheetState extends State<_LyricsExportSheet> {
  late final _formats = LyricsExportFormat.values.where((f) => f.availableFor(widget.lines)).toList();
  late LyricsExportFormat _format = _formats.first;
  bool _busy = false;

  LyricsExportMetadata get _metadata {
    final ticks = widget.item.runTimeTicks;
    return LyricsExportMetadata(
      title: widget.item.name,
      artist: widget.item.artists?.join(", ") ?? widget.item.albumArtist,
      album: widget.item.album,
      length: ticks == null ? null : Duration(microseconds: ticks ~/ 10),
    );
  }

  String get _content => LyricsExporter.export(
    _format,
    widget.lines,
    metadata: _metadata,
    offsetMs: LyricsOffsetService.offsetMs(widget.item.id),
  );

  String _label(AppLocalizations l10n, LyricsExportFormat format) => switch (format) {
    LyricsExportFormat.lrc => l10n.lyricsExportFormatLrc,
    LyricsExportFormat.enhancedLrc => l10n.lyricsExportFormatEnhancedLrc,
    LyricsExportFormat.srt => l10n.lyricsExportFormatSrt,
    LyricsExportFormat.txt => l10n.lyricsExportFormatTxt,
  };

  void _toast(ScaffoldMessengerState messenger, String message) =>
      messenger.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _content));
    if (mounted) Navigator.of(context).pop();
    _toast(messenger, l10n.lyricsExportCopied);
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final name = LyricsExporter.fileName(_metadata, _format);
    final bytes = utf8.encode(_content);
    setState(() => _busy = true);
    try {
      if (isDesktop) {
        final saved = await FilePicker.saveFile(
          dialogTitle: l10n.lyricsExport,
          fileName: name,
          mimeType: _format.mimeType,
          bytes: bytes,
        );
        if (saved == null) return;
        navigator.pop();
        _toast(messenger, l10n.lyricsExportSaved);
      } else {
        final file = File(p.join((await getTemporaryDirectory()).path, name));
        await file.writeAsBytes(bytes, flush: true);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: _format.mimeType)],
            subject: widget.item.name,
            sharePositionOrigin: origin,
          ),
        );
        navigator.pop();
      }
    } catch (e, stack) {
      _toast(messenger, l10n.lyricsExportFailed(FriendlyError.report(_log, "Lyrics export", e, stack)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(l10n.lyricsExport, style: Theme.of(context).textTheme.titleLarge),
          ),
          RadioGroup<LyricsExportFormat>(
            groupValue: _format,
            onChanged: (value) => setState(() => _format = value ?? _format),
            child: Column(
              children: [
                for (final format in _formats)
                  RadioListTile<LyricsExportFormat>(
                    value: format,
                    title: Text(_label(l10n, format)),
                    subtitle: Text(".${format.extension}"),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _copy,
                  icon: const Icon(TablerIcons.copy),
                  label: Text(l10n.lyricsExportCopy),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: Icon(isDesktop ? TablerIcons.device_floppy : TablerIcons.share),
                  label: Text(isDesktop ? l10n.lyricsExportSave : l10n.lyricsExportShare),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
