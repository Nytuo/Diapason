import 'package:diapason/components/connect_devices.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Diapason Connect's devices, outside the player. Playback is normally moved from the devices button of the player
/// (the output menu); this page lists the same devices and also offers sending accounts to a TV.
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  static const routeName = "/connect";

  ConnectService get _connect => GetIt.instance<ConnectService>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Diapason Connect"),
        actions: [
          IconButton(
            tooltip: "Look again",
            icon: const Icon(TablerIcons.refresh),
            onPressed: () async {
              await _connect.stopDiscovery();
              await _connect.startDiscovery();
            },
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                "Pick a device to play there. The whole app then controls it, like a remote: play, pause, skip, "
                "queue, lyrics. You can also do this from the devices button of the player.\n\n"
                "Other devices need Diapason open, on the same Wi-Fi, with the same accounts.",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          const ConnectDeviceList(),
        ],
      ),
    );
  }
}
