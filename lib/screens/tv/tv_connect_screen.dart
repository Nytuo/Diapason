import 'package:diapason/screens/tv/tv_widgets.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_player_bridge.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class TvConnectScreen extends StatefulWidget {
  const TvConnectScreen({super.key});

  static const routeName = "/tv/connect";

  @override
  State<TvConnectScreen> createState() => _TvConnectScreenState();
}

class _TvConnectScreenState extends State<TvConnectScreen> {
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

  Future<void> _sendQueue() async {
    final songs = GetIt.instance<ConnectPlayerBridge>().currentQueueForCasting();
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Nothing is playing here to send.")));
      return;
    }
    await _connect.castQueue(songs);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Sent ${songs.length} track(s)")));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(48.0),
          child: ValueListenableBuilder<ConnectDevice?>(
            valueListenable: _connect.connectedDevice,
            builder: (context, connected, _) => connected == null
                ? _DeviceList(connect: _connect)
                : _RemotePanel(device: connected, connect: _connect, onSendQueue: _sendQueue),
          ),
        ),
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.connect});

  final ConnectService connect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Diapason Connect", style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Colors.white)),
        const SizedBox(height: 8.0),
        const Text(
          "Play on, and control, your other Diapason devices. They show up here when they are on the same network.",
          style: TextStyle(color: Colors.white60, fontSize: 18.0),
        ),
        const SizedBox(height: 32.0),
        Expanded(
          child: ValueListenableBuilder<List<ConnectDevice>>(
            valueListenable: connect.devices,
            builder: (context, devices, _) {
              if (devices.isEmpty) {
                return const Center(
                  child: Text(
                    "Looking for devices…\nOpen Diapason on another device on this network.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 22.0),
                  ),
                );
              }
              return ListView(
                children: [
                  for (var i = 0; i < devices.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: TvFocusable(
                        autofocus: i == 0,
                        onPressed: () => connect.connect(devices[i]),
                        builder: (context, focused) => AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          padding: const EdgeInsets.all(20.0),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12.0),
                            color: focused
                                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)
                                : Colors.white10,
                            border: Border.all(
                              color: focused ? Theme.of(context).colorScheme.primary : Colors.transparent,
                              width: 3.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(TablerIcons.device_speaker, color: Colors.white, size: 36.0),
                              const SizedBox(width: 20.0),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(devices[i].name, style: const TextStyle(color: Colors.white, fontSize: 24.0)),
                                    Text(
                                      Uri.parse(devices[i].baseUrl).host,
                                      style: const TextStyle(color: Colors.white54, fontSize: 16.0),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(TablerIcons.chevron_right, color: Colors.white54),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RemotePanel extends StatelessWidget {
  const _RemotePanel({required this.device, required this.connect, required this.onSendQueue});

  final ConnectDevice device;
  final ConnectService connect;
  final VoidCallback onSendQueue;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectStatus?>(
      valueListenable: connect.remoteStatus,
      builder: (context, status, _) {
        final song = status?.song;
        final playing = status?.isPlaying ?? false;
        final volume = (status?.volume ?? 1.0).clamp(0.0, 1.0);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "Playing on ${device.name}",
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 32.0),
            Text(
              song?.title ?? (status == null ? "Connecting…" : "Nothing playing"),
              style: const TextStyle(color: Colors.white, fontSize: 32.0),
              textAlign: TextAlign.center,
            ),
            if (song != null)
              Text("${song.artist} · ${song.album}", style: const TextStyle(color: Colors.white60, fontSize: 20.0)),
            const SizedBox(height: 32.0),
            if (song != null && song.duration > 0)
              SizedBox(
                width: 600.0,
                child: LinearProgressIndicator(value: ((status?.position ?? 0) / song.duration).clamp(0.0, 1.0)),
              ),
            const SizedBox(height: 40.0),
            Wrap(
              spacing: 20.0,
              runSpacing: 20.0,
              alignment: WrapAlignment.center,
              children: [
                TvPillButton(
                  icon: TablerIcons.player_skip_back,
                  label: "Previous",
                  onPressed: () => connect.sendCommand("previous"),
                ),
                TvPillButton(
                  autofocus: true,
                  icon: playing ? TablerIcons.player_pause : TablerIcons.player_play,
                  label: playing ? "Pause" : "Play",
                  onPressed: () => connect.sendCommand(playing ? "pause" : "play"),
                ),
                TvPillButton(
                  icon: TablerIcons.player_skip_forward,
                  label: "Next",
                  onPressed: () => connect.sendCommand("next"),
                ),
                TvPillButton(
                  icon: TablerIcons.volume_2,
                  label: "Volume −",
                  onPressed: () => connect.sendCommand("volume", volume: (volume - 0.1).clamp(0.0, 1.0)),
                ),
                TvPillButton(
                  icon: TablerIcons.volume,
                  label: "Volume +",
                  onPressed: () => connect.sendCommand("volume", volume: (volume + 0.1).clamp(0.0, 1.0)),
                ),
              ],
            ),
            const SizedBox(height: 32.0),
            Wrap(
              spacing: 20.0,
              children: [
                TvPillButton(icon: TablerIcons.playlist, label: "Send what's playing here", onPressed: onSendQueue),
                TvPillButton(icon: TablerIcons.plug_connected_x, label: "Disconnect", onPressed: connect.disconnect),
              ],
            ),
          ],
        );
      },
    );
  }
}
