import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/radio_station.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/radio/radio_station_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _log = Logger("RadioStations");

/// Starts [item] (a station from Radio Browser, the user's own list or a
/// server) as a one-item live queue.
Future<void> playRadioItem(BuildContext context, BaseItemDto item) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await GetIt.instance<QueueService>().startPlayback(
      items: [item],
      source: QueueItemSource(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: item.album ?? item.name ?? l10n.radioStationsTitle,
        ),
        id: item.id,
      ),
    );
  } catch (e, stack) {
    final why = FriendlyError.report(_log, "Tune in to '${item.name}'", e, stack);
    messenger?.showSnackBar(SnackBar(content: Text(l10n.radioStationsPlayError(why))));
  }
}

Future<void> playRadioStation(BuildContext context, RadioStation station) =>
    playRadioItem(context, station.toBaseItem(isFavorite: RadioStationStore.isSaved(station.id)));

/// The station's logo, or a radio icon when it has none (or it fails to load).
class RadioStationLogo extends StatelessWidget {
  const RadioStationLogo({super.key, this.url, this.size = 48});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(TablerIcons.radio, size: size * 0.5),
    );
    final uri = Uri.tryParse(url ?? "");
    if (uri == null || !(uri.isScheme("http") || uri.isScheme("https"))) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        uri.toString(),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// One station in a list: logo, name, country/format/tags, a save toggle and,
/// for the user's own stations, edit and delete.
class RadioStationTile extends StatelessWidget {
  const RadioStationTile({super.key, required this.station, this.isSaved = false, this.onEdit});

  final RadioStation station;
  final bool isSaved;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final details = [
      if ((station.country ?? "").isNotEmpty) station.country!,
      if (station.formatLabel.isNotEmpty) station.formatLabel,
      if (station.tags.isNotEmpty) station.tags.take(3).join(", "),
      if (station.isCustom) Uri.tryParse(station.streamUrl)?.host ?? "",
    ].where((s) => s.isNotEmpty).join(" · ");

    return ListTile(
      leading: RadioStationLogo(url: station.faviconUrl),
      title: Text(station.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: details.isEmpty ? null : Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => playRadioStation(context, station),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: isSaved ? l10n.radioStationsUnsave : l10n.radioStationsSave,
            icon: Icon(isSaved ? Icons.favorite : Icons.favorite_border),
            onPressed: () => isSaved ? RadioStationStore.remove(station.id) : RadioStationStore.save(station),
          ),
          if (station.isCustom && isSaved && onEdit != null)
            PopupMenuButton<VoidCallback>(
              onSelected: (action) => action(),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: onEdit,
                  child: ListTile(leading: const Icon(TablerIcons.edit), title: Text(l10n.radioStationsEdit)),
                ),
                PopupMenuItem(
                  value: () => confirmDeleteStation(context, station),
                  child: ListTile(leading: const Icon(TablerIcons.trash), title: Text(l10n.radioStationsDelete)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

Future<void> confirmDeleteStation(BuildContext context, RadioStation station) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.radioStationsDeleteConfirm(station.name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.radioStationsDelete)),
      ],
    ),
  );
  if (confirmed ?? false) await RadioStationStore.remove(station.id);
}

/// Add (when [station] is null) or edit one of the user's own stations.
Future<void> showRadioStationDialog(BuildContext context, {RadioStation? station}) => showDialog<void>(
  context: context,
  builder: (_) => _RadioStationDialog(station: station),
);

class _RadioStationDialog extends StatefulWidget {
  const _RadioStationDialog({this.station});

  final RadioStation? station;

  @override
  State<_RadioStationDialog> createState() => _RadioStationDialogState();
}

class _RadioStationDialogState extends State<_RadioStationDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.station?.name);
  late final _url = TextEditingController(text: widget.station?.streamUrl);
  late final _favicon = TextEditingController(text: widget.station?.faviconUrl);
  late final _homepage = TextEditingController(text: widget.station?.homepage);
  late final _tags = TextEditingController(text: widget.station?.tags.join(", "));

  @override
  void dispose() {
    for (final c in [_name, _url, _favicon, _homepage, _tags]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _optional(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final tags = _tags.text.split(",").map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    final existing = widget.station;
    if (existing == null) {
      await RadioStationStore.addCustom(
        name: _name.text,
        streamUrl: _url.text,
        faviconUrl: _favicon.text,
        homepage: _homepage.text,
        tags: tags,
      );
    } else {
      await RadioStationStore.save(
        RadioStation(
          id: existing.id,
          name: _name.text.trim(),
          streamUrl: _url.text.trim(),
          faviconUrl: _optional(_favicon),
          homepage: _optional(_homepage),
          tags: tags,
          isCustom: true,
        ),
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    String? optionalUrl(String? v) =>
        (v ?? "").trim().isEmpty || RadioStationStore.isValidStreamUrl(v!) ? null : l10n.radioStationsInvalidUrl;

    return AlertDialog(
      title: Text(widget.station == null ? l10n.radioStationsAdd : l10n.radioStationsEdit),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: InputDecoration(labelText: l10n.radioStationsName),
                  validator: (v) => (v ?? "").trim().isEmpty ? l10n.radioStationsNameRequired : null,
                ),
                TextFormField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l10n.radioStationsStreamUrl,
                    hintText: l10n.radioStationsStreamUrlHint,
                  ),
                  validator: (v) => RadioStationStore.isValidStreamUrl(v ?? "") ? null : l10n.radioStationsInvalidUrl,
                ),
                TextFormField(
                  controller: _favicon,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: l10n.radioStationsFaviconUrl),
                  validator: optionalUrl,
                ),
                TextFormField(
                  controller: _homepage,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: l10n.radioStationsHomepage),
                  validator: optionalUrl,
                ),
                TextFormField(
                  controller: _tags,
                  decoration: InputDecoration(labelText: l10n.radioStationsTagsField),
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.save)),
      ],
    );
  }
}
