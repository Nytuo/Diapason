import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/media_source_service.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_player_bridge.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  static const routeName = "/connect";

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  ConnectService get _connect => GetIt.instance<ConnectService>();

  @override
  void initState() {
    super.initState();
    _connect.startDiscovery();
  }

  @override
  void dispose() {
    _connect.stopDiscovery();
    super.dispose();
  }

  Future<void> _cast() async {
    final songs = GetIt.instance<ConnectPlayerBridge>().currentQueueForCasting();
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Nothing in the queue to send.")));
      return;
    }
    await _connect.castQueue(songs);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Sent ${songs.length} track(s)")));
    }
  }

  /// Pushes this device's server accounts to another one (a TV), so nobody has to type them in with a remote.
  Future<void> _sendAccounts(ConnectDevice device) async {
    final sources = GetIt.instance<MediaSourceService>().sources
        .where((s) => s.kind.isConfigurable && s.kind != MediaSourceKind.local)
        .toList();
    if (sources.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("There are no server accounts to send.")));
      return;
    }
    final picked = await showDialog<({List<MediaSourceConfig> chosen, String profile})>(
      context: context,
      builder: (context) => _SendAccountsDialog(device: device, sources: sources),
    );
    if (picked == null || picked.chosen.isEmpty) return;

    final ok = await _connect.sendSources(
      device,
      picked.chosen.map((s) => s.toTvOSStorageJson()).toList(),
      profileName: picked.profile,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? "Sent. Accept it on ${device.name}."
              : "${device.name} did not take them. Open Diapason on its start screen and try again.",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Diapason Connect"),
        actions: [
          IconButton(
            icon: const Icon(TablerIcons.refresh),
            onPressed: () async {
              await _connect.stopDiscovery();
              await _connect.startDiscovery();
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<ConnectDevice?>(
        valueListenable: _connect.connectedDevice,
        builder: (context, connected, _) {
          if (connected != null) return _RemoteControl(device: connected, onCast: _cast);

          return ValueListenableBuilder<List<ConnectDevice>>(
            valueListenable: _connect.devices,
            builder: (context, devices, _) {
              if (devices.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Text(
                      "Looking for other Diapason devices on your network…\n\n"
                      "They need to be on the same Wi-Fi, with Diapason open.",
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView(
                children: [
                  for (final device in devices)
                    ListTile(
                      leading: const Icon(TablerIcons.device_speaker),
                      title: Text(device.name),
                      subtitle: Text(Uri.parse(device.baseUrl).host),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: "Send my accounts to this device",
                            icon: const Icon(TablerIcons.user_plus),
                            onPressed: () => _sendAccounts(device),
                          ),
                          const Icon(TablerIcons.chevron_right),
                        ],
                      ),
                      onTap: () => _connect.connect(device),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Shown while we're driving another device. Deliberately not a remote control:
/// the now-playing bar owns the transport, artwork and metadata, exactly as it
/// does for local playback. This just states where audio is going and offers the
/// actions that only make sense here.
class _RemoteControl extends StatelessWidget {
  const _RemoteControl({required this.device, required this.onCast});

  final ConnectDevice device;
  final VoidCallback onCast;

  ConnectService get _connect => GetIt.instance<ConnectService>();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectStatus?>(
      valueListenable: _connect.remoteStatus,
      builder: (context, status, _) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(TablerIcons.device_speaker, size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16.0),
              Text(
                "Playing on ${device.name}",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8.0),
              Text(
                status == null ? "Connecting…" : "Use the player controls as usual — they're driving this device.",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 32.0),
              FilledButton.icon(
                onPressed: onCast,
                icon: const Icon(TablerIcons.playlist),
                label: const Text("Send my queue to this device"),
              ),
              const SizedBox(height: 8.0),
              TextButton.icon(
                onPressed: _connect.disconnect,
                icon: const Icon(TablerIcons.plug_connected_x),
                label: const Text("Disconnect"),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SendAccountsDialog extends StatefulWidget {
  const _SendAccountsDialog({required this.device, required this.sources});

  final ConnectDevice device;
  final List<MediaSourceConfig> sources;

  @override
  State<_SendAccountsDialog> createState() => _SendAccountsDialogState();
}

class _SendAccountsDialogState extends State<_SendAccountsDialog> {
  late final Set<String> _chosen = widget.sources.map((s) => s.sourceId).toSet();
  final _profile = TextEditingController(text: "Home");

  @override
  void dispose() {
    _profile.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("Send accounts to ${widget.device.name}"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _profile,
              decoration: const InputDecoration(labelText: "Profile on that device"),
            ),
            const SizedBox(height: 8.0),
            for (final source in widget.sources)
              CheckboxListTile(
                value: _chosen.contains(source.sourceId),
                title: Text(source.name),
                subtitle: Text(source.publicAddress.isEmpty ? source.kind.name : source.publicAddress),
                onChanged: (on) =>
                    setState(() => on == true ? _chosen.add(source.sourceId) : _chosen.remove(source.sourceId)),
              ),
            const SizedBox(height: 8.0),
            const Text(
              "Passwords and tokens are sent over your local network as they are. Only do this at home.",
              style: TextStyle(fontSize: 12.0),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            chosen: widget.sources.where((s) => _chosen.contains(s.sourceId)).toList(),
            profile: _profile.text.trim().isEmpty ? "Home" : _profile.text.trim(),
          )),
          child: const Text("Send"),
        ),
      ],
    );
  }
}
