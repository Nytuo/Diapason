import 'dart:io';

import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/menus/output_menu.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/media_source_service.dart';
import 'package:diapason/services/cast/cast_service.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_remote_controller.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/feedback_helper.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

String connectDisplayName(String name) =>
    name.replaceFirstMapped(RegExp(r"^Diapason \((.*)\)$"), (match) => match.group(1)!);

ConnectService? get _connectOrNull =>
    GetIt.instance.isRegistered<ConnectService>() ? GetIt.instance<ConnectService>() : null;

ConnectRemoteController? get _sessionOrNull =>
    GetIt.instance.isRegistered<ConnectRemoteController>() ? GetIt.instance<ConnectRemoteController>() : null;

bool get _castAvailable => (Platform.isAndroid || Platform.isIOS) && GetIt.instance.isRegistered<CastService>();

/// Builds [builder] with the device playback is on (null: this one), rebuilding when it changes.
class ConnectTargetBuilder extends StatelessWidget {
  const ConnectTargetBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, ConnectDevice? device) builder;

  @override
  Widget build(BuildContext context) {
    final connect = _connectOrNull;
    if (connect == null) return builder(context, null);
    return ValueListenableBuilder<ConnectDevice?>(
      valueListenable: connect.connectedDevice,
      builder: (context, device, _) => builder(context, device),
    );
  }
}

/// The "devices" button: opens the output menu, where playback can be moved to another device. Lit up while playing
/// on one.
class ConnectDeviceButton extends StatelessWidget {
  const ConnectDeviceButton({super.key, this.size = 22, this.color, this.activeColor});

  final double size;
  final Color? color;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    return ConnectTargetBuilder(
      builder: (context, device) => IconButton(
        tooltip: device == null ? "Play on another device" : "Playing on ${device.name}",
        visualDensity: VisualDensity.compact,
        icon: Icon(
          device == null ? TablerIcons.devices : TablerIcons.device_speaker,
          size: size,
          color: device == null ? color : (activeColor ?? Theme.of(context).colorScheme.primary),
        ),
        onPressed: () => showOutputMenu(context: context),
      ),
    );
  }
}

/// A slim "Playing on <device>" strip, shown under the now playing bar and on the player while another device plays.
class ConnectPlayingOnBanner extends StatelessWidget {
  const ConnectPlayingOnBanner({super.key, this.padding = EdgeInsets.zero, this.color});

  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ConnectTargetBuilder(
      builder: (context, device) {
        if (device == null) return const SizedBox.shrink();
        final tint = color ?? Theme.of(context).colorScheme.primary;
        return Padding(
          padding: padding,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => showOutputMenu(context: context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(TablerIcons.device_speaker, size: 14, color: tint),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      "Playing on ${device.name}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tint, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The "Play on" list of the output menu: this device, the Diapason devices on the network and, on phones, Cast
/// devices. Picking one moves playback there.
class ConnectDeviceList extends StatefulWidget {
  const ConnectDeviceList({super.key});

  @override
  State<ConnectDeviceList> createState() => _ConnectDeviceListState();
}

class _ConnectDeviceListState extends State<ConnectDeviceList> {
  ConnectService? get _connect => _connectOrNull;
  ConnectRemoteController? get _session => _sessionOrNull;

  @override
  void initState() {
    super.initState();
    _connect?.startDiscovery();
    if (_castAvailable) GetIt.instance<CastService>().startDiscovery();
  }

  @override
  void dispose() {
    _connect?.stopDiscovery();
    if (_castAvailable) GetIt.instance<CastService>().stopDiscovery();
    super.dispose();
  }

  Future<void> _pick(ConnectDevice? device) async {
    final session = _session;
    if (session == null) return;
    FeedbackHelper.feedback(FeedbackType.selection);
    if (device == null) {
      await session.transferHere();
    } else {
      await session.transferTo(device);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connect = _connect;
    final session = _session;
    if (connect == null || session == null) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: ValueListenableBuilder<bool>(
        valueListenable: session.transferring,
        builder: (context, transferring, _) => ValueListenableBuilder<ConnectDevice?>(
          valueListenable: connect.connectedDevice,
          builder: (context, current, _) => ValueListenableBuilder<List<ConnectDevice>>(
            valueListenable: connect.devices,
            builder: (context, devices, _) {
              final others = [...devices, if (current != null && !devices.contains(current)) current];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedOpacity(
                    opacity: transferring ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const LinearProgressIndicator(minHeight: 2),
                  ),
                  _DeviceTile(
                    icon: Platform.isAndroid || Platform.isIOS ? TablerIcons.device_mobile : TablerIcons.device_laptop,
                    title: "This device",
                    subtitle: connectDisplayName(connect.deviceName),
                    selected: current == null,
                    enabled: !transferring,
                    onTap: () => _pick(null),
                  ),
                  for (final device in others)
                    _DeviceTile(
                      icon: TablerIcons.device_speaker,
                      title: connectDisplayName(device.name),
                      subtitle: current == device ? "Playing here" : "Diapason Connect",
                      selected: current == device,
                      enabled: !transferring,
                      onTap: () => _pick(device),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(TablerIcons.dots_vertical, size: 18),
                        onSelected: (_) => sendAccountsTo(context, device),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: "accounts", child: Text("Send my accounts to this device")),
                        ],
                      ),
                    ),
                  if (others.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        "Looking for other Diapason devices on your Wi-Fi… Open Diapason on them to see them here.",
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  if (_castAvailable) const _CastDevices(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ListTile(
      enabled: enabled,
      leading: Icon(icon, color: selected ? accent : null),
      title: Text(
        title,
        style: TextStyle(color: selected ? accent : null, fontWeight: selected ? FontWeight.w600 : null),
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) Icon(TablerIcons.volume, color: accent, size: 18),
          if (trailing != null) trailing!,
        ],
      ),
      onTap: selected ? null : onTap,
    );
  }
}

class _CastDevices extends StatelessWidget {
  const _CastDevices();

  Future<void> _cast(BuildContext context, GoogleCastDevice device) async {
    final cast = GetIt.instance<CastService>();
    await cast.connect(device);
    final track = GetIt.instance<QueueService>().getQueue().currentTrack?.baseItem;
    if (track == null) {
      GlobalSnackbar.message((_) => "Connected. Play something to send it here.");
      return;
    }
    final sent = await cast.cast(track);
    GlobalSnackbar.message(
      (_) =>
          sent ? "Casting to ${device.friendlyName}" : "That track is a local file, so the Cast device can't reach it.",
    );
  }

  @override
  Widget build(BuildContext context) {
    final cast = GetIt.instance<CastService>();
    return StreamBuilder<List<GoogleCastDevice>>(
      stream: cast.devices,
      builder: (context, snapshot) {
        final devices = snapshot.data ?? const [];
        if (devices.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 16, top: 8, bottom: 4),
              child: Text("Google Cast", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            for (final device in devices)
              ListTile(
                leading: const Icon(TablerIcons.cast),
                title: Text(device.friendlyName),
                subtitle: Text(device.modelName ?? "Cast"),
                trailing: cast.isCasting
                    ? IconButton(icon: const Icon(TablerIcons.x), onPressed: cast.disconnect)
                    : null,
                onTap: () => _cast(context, device),
              ),
          ],
        );
      },
    );
  }
}

/// Pushes this device's server accounts to another one (a TV), so nobody has to type them in with a remote.
Future<void> sendAccountsTo(BuildContext context, ConnectDevice device) async {
  final connect = _connectOrNull;
  if (connect == null) return;
  final sources = GetIt.instance<MediaSourceService>().sources
      .where((s) => s.kind.isConfigurable && s.kind != MediaSourceKind.local)
      .toList();
  if (sources.isEmpty) {
    GlobalSnackbar.message((_) => "There are no server accounts to send.");
    return;
  }
  final picked = await showDialog<({List<MediaSourceConfig> chosen, String profile})>(
    context: context,
    builder: (context) => SendAccountsDialog(device: device, sources: sources),
  );
  if (picked == null || picked.chosen.isEmpty) return;

  final ok = await connect.sendSources(
    device,
    picked.chosen.map((s) => s.toTvOSStorageJson()).toList(),
    profileName: picked.profile,
  );
  GlobalSnackbar.message(
    (_) => ok
        ? "Sent. Accept it on ${device.name}."
        : "${device.name} did not take them. Open Diapason on its start screen and try again.",
  );
}

class SendAccountsDialog extends StatefulWidget {
  const SendAccountsDialog({super.key, required this.device, required this.sources});

  final ConnectDevice device;
  final List<MediaSourceConfig> sources;

  @override
  State<SendAccountsDialog> createState() => _SendAccountsDialogState();
}

class _SendAccountsDialogState extends State<SendAccountsDialog> {
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
