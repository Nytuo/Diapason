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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Sent ${songs.length} track(s)")));
    }
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
                      trailing: const Icon(TablerIcons.chevron_right),
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
                status == null
                    ? "Connecting…"
                    : "Use the player controls as usual — they're driving this device.",
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
