import 'dart:io';

import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/uploader/local_file_upload.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/services/uploader/uploader_discovery_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

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

  UploaderClient get _client => GetIt.instance<UploaderClient>();

  bool _showToken = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  UploaderCapabilities? _caps;
  String? _uploadStatus;

  @override
  void initState() {
    super.initState();
    _discovery.devices.addListener(_onDevicesChanged);
    _discovery.start();
    _refreshCapabilities();
  }

  Future<void> _refreshCapabilities() async {
    final caps = await _client.capabilities();
    if (mounted) setState(() => _caps = caps);
    // The YouTube tab appears or disappears with what the uploader can do.
    await GetIt.instance<YouTubeAvailability>().refresh();
  }

  Future<void> _testConnection() async {
    _save(quiet: true);
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final caps = await _client.capabilities();
    final problem = caps.problem;
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = problem == null;
      _caps = caps;
      _testResult =
          problem ??
          (caps.ytdlp
              ? "Connected. YouTube via yt-dlp is available (${caps.ytdlpVersion ?? "unknown version"})."
                    "${caps.jsRuntime == null ? " Note: the server has no JavaScript runtime, so some videos may fail." : ""}"
              : "Connected. (The server's YouTube feature is off.)");
    });
    await GetIt.instance<YouTubeAvailability>().refresh();
  }

  Future<void> _pickAndUpload() async {
    _save(quiet: true);
    if (!_client.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Set a usable uploader address first.")));
      return;
    }
    final summary = await LocalFileUpload.pickAndUpload(
      onProgress: (done, total, name) {
        if (!mounted) return;
        setState(() => _uploadStatus = done >= total ? null : "Uploading ${done + 1} of $total — $name");
      },
    );
    if (!mounted) return;
    setState(() => _uploadStatus = null);
    if (summary == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(summary.failures.isEmpty ? summary.message : "${summary.message}\n${summary.failures.first}"),
      ),
    );
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

  void _save({bool quiet = false}) {
    var url = _url.text.trim();
    while (url.endsWith("/")) {
      url = url.substring(0, url.length - 1);
    }
    _url.text = url;
    FinampSetters.setUploaderUrl(url);
    FinampSetters.setUploaderToken(_token.text.trim());
    if (!quiet) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Uploader saved")));
      _refreshCapabilities();
    }
    setState(() {});
  }

  Future<void> _useDiscovered(DiscoveredUploader device) async {
    final messenger = ScaffoldMessenger.of(context);
    _url.text = device.baseUrl;
    FinampSetters.setUploaderEnabled(true);

    if (!device.canPair) {
      _save();
      messenger.showSnackBar(SnackBar(content: Text("Using ${device.name} — paste its token below, then Save")));
      return;
    }

    try {
      final token = await _client.pair(device.baseUrl, "Diapason on ${_deviceName()}");
      _token.text = token;
      if (!mounted) return;
      _save(quiet: true);
      _refreshCapabilities();
      messenger.showSnackBar(SnackBar(content: Text("Paired with ${device.name}")));
    } on UploaderException catch (e) {
      if (!mounted) return;
      _save(quiet: true);
      messenger.showSnackBar(SnackBar(content: Text("${e.message} You can paste its token below instead.")));
    }
  }

  static String _deviceName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return Platform.operatingSystem;
    }
  }

  Future<void> _allowAnotherDevice() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _client.openPairing();
      messenger.showSnackBar(
        const SnackBar(content: Text("Pairing is open for a few minutes — tap “Pair” in the other device's app.")),
      );
    } on UploaderException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(finampSettingsProvider.uploaderEnabled);
    final policy = UploaderNetworkPolicy.fromName(ref.watch(finampSettingsProvider.uploaderNetworkPolicy));

    final proxy = ref.watch(finampSettingsProvider.uploaderYtProxy);

    final url = _url.text.trim();
    final allowInsecure = ref.watch(finampSettingsProvider.uploaderAllowInsecure);
    final blockReason = url.isEmpty ? null : UploaderClient.blockReason(url, policy, allowInsecure: allowInsecure);
    final cleartext = url.startsWith("http://") && blockReason == null;
    final host = Uri.tryParse(url)?.host ?? "";
    // Plain HTTP to a name that doesn't look private: offer the "already secure" escape hatch.
    final offerInsecure = url.startsWith("http://") && host.isNotEmpty && !UploaderClient.isPrivateHost(host);

    return Scaffold(
      appBar: AppBar(title: const Text("Uploader")),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          const Text(
            "Navidrome and Plex can't be written to directly. A diapason-uploader sidecar adds tracks into "
            "your library — files from this device, tracks you download, or songs it fetches from YouTube "
            "for you.",
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
                  leading: Icon(device.canPair ? TablerIcons.link : TablerIcons.server),
                  title: Text(device.name),
                  subtitle: Text(device.canPair ? "${device.baseUrl} • one tap to pair" : device.baseUrl),
                  trailing: FilledButton.tonal(
                    onPressed: () => _useDiscovered(device),
                    child: Text(device.canPair ? "Pair" : "Use"),
                  ),
                ),
              ),
            const SizedBox(height: 8.0),
          ] else if (_discovery.isDiscovering)
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: Row(
                children: [
                  const SizedBox(width: 16.0, height: 16.0, child: CircularProgressIndicator(strokeWidth: 2.0)),
                  const SizedBox(width: 12.0),
                  Text("Looking for uploaders on your network…", style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),

          TextField(
            controller: _url,
            autocorrect: false,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: "Sidecar address", hintText: "https://music.example.com"),
          ),
          const SizedBox(height: 16.0),
          TextField(
            controller: _token,
            obscureText: !_showToken,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: "Token",
              suffixIcon: IconButton(
                icon: Icon(_showToken ? TablerIcons.eye_off : TablerIcons.eye),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
            ),
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
            subtitle: const Text(
              "Allows uploading over the internet. Requires https:// for anything outside your network.",
            ),
            onChanged: (value) => FinampSetters.setUploaderNetworkPolicy(value!.name),
          ),

          if (blockReason != null)
            _notice(TablerIcons.alert_triangle, blockReason, Theme.of(context).colorScheme.error)
          else if (cleartext)
            _notice(
              TablerIcons.lock_open,
              "This connection isn't encrypted by the app. That's fine on your home network or inside a VPN/tunnel "
              "you trust; otherwise serve the uploader over https.",
              Theme.of(context).colorScheme.tertiary,
            ),
          if (offerInsecure)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("My connection is already secure"),
              subtitle: const Text(
                "I reach this server through a VPN or encrypted tunnel (WireGuard, Tailscale, SSH…), so plain "
                "http:// is fine.",
              ),
              value: allowInsecure,
              onChanged: (value) => FinampSetters.setUploaderAllowInsecure(value),
            ),

          const SizedBox(height: 24.0),
          Row(
            children: [
              Expanded(
                child: FilledButton(onPressed: _save, child: const Text("Save")),
              ),
              const SizedBox(width: 12.0),
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _testConnection,
                  child: _testing
                      ? const SizedBox(width: 16.0, height: 16.0, child: CircularProgressIndicator(strokeWidth: 2.0))
                      : const Text("Test connection"),
                ),
              ),
            ],
          ),
          if (_testResult != null)
            _notice(
              _testOk ? TablerIcons.circle_check : TablerIcons.circle_x,
              _testResult!,
              _testOk ? Colors.green : Theme.of(context).colorScheme.error,
            ),

          if (_client.isConfigured && (_caps?.pairing ?? false)) ...[
            const SizedBox(height: 8.0),
            TextButton.icon(
              onPressed: _allowAnotherDevice,
              icon: const Icon(TablerIcons.device_mobile_plus),
              label: const Text("Allow another device to pair"),
            ),
          ],

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Upload automatically only on Wi-Fi"),
            subtitle: const Text(
              "Downloaded tracks wait instead of using mobile data. Manual uploads always go through.",
            ),
            value: ref.watch(finampSettingsProvider.uploaderWifiOnly),
            onChanged: (value) => FinampSetters.setUploaderWifiOnly(value),
          ),

          const SizedBox(height: 32.0),
          Text("Upload from this device", style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4.0),
          const Text("Pick audio files from your storage and send them to your server's library."),
          const SizedBox(height: 8.0),
          OutlinedButton.icon(
            onPressed: _uploadStatus != null || blockReason != null || url.isEmpty ? null : _pickAndUpload,
            icon: const Icon(TablerIcons.upload),
            label: const Text("Choose files…"),
          ),
          if (_uploadStatus != null) ...[
            const SizedBox(height: 8.0),
            const LinearProgressIndicator(),
            const SizedBox(height: 4.0),
            Text(_uploadStatus!, style: Theme.of(context).textTheme.bodySmall),
          ],

          const SizedBox(height: 32.0),
          Text("YouTube through your server", style: Theme.of(context).textTheme.titleSmall),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Use the uploader for YouTube"),
            subtitle: Text(
              _caps == null || (_caps!.reachable && _caps!.ytdlp)
                  ? "Search, play and download YouTube via yt-dlp running on your server. It updates itself, so "
                        "YouTube changes don't break the app, and your phone never talks to YouTube directly."
                  : !_caps!.reachable
                  ? "Can't use it right now: ${_caps!.problem ?? "the uploader can't be reached."}"
                  : "Your uploader is connected but its YouTube feature is off (set DIAPASON_YTDLP_ENABLED=true on it).",
            ),
            value: proxy,
            onChanged: blockReason == null && url.isNotEmpty
                ? (value) async {
                    FinampSetters.setUploaderYtProxy(value);
                    await GetIt.instance<YouTubeAvailability>().refresh();
                  }
                : null,
          ),
          const SizedBox(height: 16.0),
        ],
      ),
    );
  }

  Widget _notice(IconData icon, String text, Color color) => Padding(
    padding: const EdgeInsets.only(top: 12.0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 8.0),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
