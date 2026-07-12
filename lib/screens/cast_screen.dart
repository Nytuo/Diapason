import 'package:diapason/services/cast/cast_service.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class CastScreen extends StatefulWidget {
  const CastScreen({super.key});

  static const routeName = "/cast";

  @override
  State<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends State<CastScreen> {
  CastService get _cast => GetIt.instance<CastService>();

  @override
  void initState() {
    super.initState();
    _cast.startDiscovery();
  }

  @override
  void dispose() {
    _cast.stopDiscovery();
    super.dispose();
  }

  Future<void> _connectAndCast(GoogleCastDevice device) async {
    await _cast.connect(device);
    if (!mounted) return;

    final track = GetIt.instance<QueueService>().getQueue().currentTrack?.baseItem;
    if (track == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Connected. Play something to send it here.")));
      return;
    }

    final sent = await _cast.cast(track);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? "Casting to ${device.friendlyName}"
              : "That track is a local file, so the Cast device can't reach it.",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Cast")),
      body: StreamBuilder<GoogleCastSession?>(
        stream: _cast.session,
        builder: (context, sessionSnapshot) {
          if (sessionSnapshot.data != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(TablerIcons.cast, size: 64),
                  const SizedBox(height: 16),
                  Text("Casting to ${sessionSnapshot.data?.device?.friendlyName ?? "a device"}"),
                  const SizedBox(height: 24),
                  OutlinedButton(onPressed: _cast.disconnect, child: const Text("Stop casting")),
                ],
              ),
            );
          }

          return StreamBuilder<List<GoogleCastDevice>>(
            stream: _cast.devices,
            builder: (context, snapshot) {
              final devices = snapshot.data ?? const [];
              if (devices.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Text(
                      "Looking for Cast devices…\n\nThey need to be on the same Wi-Fi.",
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              return ListView(
                children: [
                  for (final device in devices)
                    ListTile(
                      leading: const Icon(TablerIcons.cast),
                      title: Text(device.friendlyName),
                      subtitle: Text(device.modelName ?? ""),
                      onTap: () => _connectAndCast(device),
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
