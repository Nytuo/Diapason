import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/dlna/dlna_protocol.dart';
import 'package:diapason/services/dlna/ssdp_discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:logging/logging.dart';

final _log = Logger("DlnaDiscoveryList");

/// DLNA media servers found on the LAN with SSDP; tapping one fills the
/// source form. Discovery can find nothing (iOS without the multicast
/// entitlement, another subnet): the form's address field still works.
class DlnaDiscoveryList extends StatefulWidget {
  const DlnaDiscoveryList({super.key, required this.onSelected, this.selectedLocation, this.discover});

  final void Function(DlnaDevice device) onSelected;
  final String? selectedLocation;

  /// Replaces SSDP in tests.
  final Future<List<DlnaDevice>> Function()? discover;

  @override
  State<DlnaDiscoveryList> createState() => _DlnaDiscoveryListState();
}

class _DlnaDiscoveryListState extends State<DlnaDiscoveryList> {
  List<DlnaDevice> _devices = const [];
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  void _scan() {
    setState(() => _scanning = true);
    _discover();
  }

  Future<void> _discover() async {
    List<DlnaDevice> found;
    try {
      found = await (widget.discover ?? () => SsdpDiscovery().discover())();
    } catch (e) {
      _log.info("DLNA discovery failed: $e");
      found = const [];
    }
    if (!mounted) return;
    setState(() {
      _devices = found;
      _scanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(l10n.dlnaDiscoveredServers, style: theme.textTheme.titleSmall)),
            if (_scanning)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else
              IconButton(tooltip: l10n.dlnaScanAgain, icon: const Icon(TablerIcons.refresh), onPressed: _scan),
          ],
        ),
        if (_scanning && _devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(l10n.dlnaScanning, style: theme.textTheme.bodySmall),
          )
        else if (_devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Text(l10n.dlnaNoServersFound, style: theme.textTheme.bodySmall),
          ),
        for (final device in _devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(TablerIcons.server_2),
            title: Text(device.friendlyName),
            subtitle: Text(
              [device.product, device.location.host].where((s) => s.isNotEmpty).join(" · "),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: widget.selectedLocation == device.location.toString(),
            trailing: widget.selectedLocation == device.location.toString()
                ? const Icon(TablerIcons.circle_check)
                : null,
            onTap: () => widget.onSelected(device),
          ),
      ],
    );
  }
}
