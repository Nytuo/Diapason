import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/uploader/uploader_discovery_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class UploaderSettingsScreen extends ConsumerStatefulWidget {
  const UploaderSettingsScreen({super.key});

  static const routeName = "/settings/uploader";

  @override
  ConsumerState<UploaderSettingsScreen> createState() => _UploaderSettingsScreenState();
}

class _UploaderSettingsScreenState extends ConsumerState<UploaderSettingsScreen> {
  late final _url = TextEditingController(text: FinampSettingsHelper.finampSettings.uploaderUrl);
  late final _token = TextEditingController(text: FinampSettingsHelper.finampSettings.uploaderToken);
  final _discovery = UploaderDiscoveryService();

  @override
  void initState() {
    super.initState();
    _discovery.devices.addListener(_onDevicesChanged);
    _discovery.start();
  }

  void _onDevicesChanged() => setState(() {});

  @override
  void dispose() {
    _discovery.devices.removeListener(_onDevicesChanged);
    _discovery.stop();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _save() {
    FinampSetters.setUploaderUrl(_url.text.trim());
    FinampSetters.setUploaderToken(_token.text.trim());
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Uploader saved")));
    setState(() {});
  }

  void _useDiscovered(DiscoveredUploader device) {
    _url.text = device.baseUrl;
    if (device.isPairable) {
      _token.text = device.pairingToken!;
    }
    FinampSetters.setUploaderEnabled(true);
    _save();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          device.isPairable ? "Paired with ${device.name}" : "Using ${device.name} — enter its token below",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(finampSettingsProvider.uploaderEnabled);
    final policy = UploaderNetworkPolicy.fromName(ref.watch(finampSettingsProvider.uploaderNetworkPolicy));

    final url = _url.text.trim();
    final blocked = url.isNotEmpty && !UploaderClient.isAllowed(url, policy);

    return Scaffold(
      appBar: AppBar(title: const Text("Uploader")),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          const Text(
            "Navidrome and Plex can't be written to directly. A diapason-uploader sidecar adds tracks you "
            "download — from YouTube, say — into your library.",
          ),
          const SizedBox(height: 16.0),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Upload downloaded tracks"),
            value: enabled,
            onChanged: (value) => FinampSetters.setUploaderEnabled(value),
          ),
          const SizedBox(height: 8.0),

          if (_discovery.devices.value.isNotEmpty) ...[
            Text("Found on your network", style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4.0),
            for (final device in _discovery.devices.value)
              Card(
                margin: const EdgeInsets.only(bottom: 8.0),
                child: ListTile(
                  leading: Icon(device.isPairable ? TablerIcons.link : TablerIcons.server),
                  title: Text(device.name),
                  subtitle: Text(device.isPairable ? "${device.baseUrl} • ready to pair" : device.baseUrl),
                  trailing: FilledButton.tonal(
                    onPressed: () => _useDiscovered(device),
                    child: Text(device.isPairable ? "Pair" : "Use"),
                  ),
                ),
              ),
            const SizedBox(height: 8.0),
          ] else if (_discovery.isDiscovering)
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16.0,
                    height: 16.0,
                    child: CircularProgressIndicator(strokeWidth: 2.0),
                  ),
                  const SizedBox(width: 12.0),
                  Text(
                    "Looking for uploaders on your network…",
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),

          TextField(
            controller: _url,
            autocorrect: false,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: "Sidecar address",
              hintText: "http://192.168.1.10:8080",
            ),
          ),
          const SizedBox(height: 16.0),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(labelText: "Token (optional)"),
          ),
          const SizedBox(height: 24.0),

          Text("Where it may upload", style: Theme.of(context).textTheme.titleSmall),
          RadioListTile<UploaderNetworkPolicy>(
            contentPadding: EdgeInsets.zero,
            value: UploaderNetworkPolicy.local,
            groupValue: policy,
            title: const Text("Local network only"),
            subtitle: const Text("Private addresses and .local names. The safe default."),
            onChanged: (value) => FinampSetters.setUploaderNetworkPolicy(value!.name),
          ),
          RadioListTile<UploaderNetworkPolicy>(
            contentPadding: EdgeInsets.zero,
            value: UploaderNetworkPolicy.internet,
            groupValue: policy,
            title: const Text("Anywhere"),
            subtitle: const Text("Allows uploading over the internet"),
            onChanged: (value) => FinampSetters.setUploaderNetworkPolicy(value!.name),
          ),

          if (blocked)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Row(
                children: [
                  Icon(TablerIcons.alert_triangle, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8.0),
                  const Expanded(
                    child: Text("That address isn't on the local network, so nothing will be uploaded."),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 24.0),
          FilledButton(onPressed: _save, child: const Text("Save")),
        ],
      ),
    );
  }
}
