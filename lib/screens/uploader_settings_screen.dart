import 'package:diapason/l10n/app_localizations.dart';
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
  late final _localUrl = TextEditingController(text: FinampSettingsHelper.finampSettings.uploaderLocalUrl);
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
    // The server can say how to reach it from outside the home network; take it if none was set.
    final publicUrl = caps.publicUrl;
    if (mounted && publicUrl != null && _url.text.trim().isEmpty) {
      _url.text = publicUrl;
      FinampSetters.setUploaderUrl(publicUrl);
    }
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
              ? AppLocalizations.of(context)!.uploaderConnectedYtdlp(
                      caps.ytdlpVersion ?? AppLocalizations.of(context)!.uploaderUnknownVersion,
                    ) +
                    (caps.jsRuntime == null ? AppLocalizations.of(context)!.uploaderNoJsRuntime : "")
              : AppLocalizations.of(context)!.uploaderConnectedYtdlpOff);
    });
    await GetIt.instance<YouTubeAvailability>().refresh();
  }

  Future<void> _pickAndUpload() async {
    _save(quiet: true);
    if (!_client.isConfigured) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.uploaderSetAddress)));
      return;
    }
    final summary = await LocalFileUpload.pickAndUpload(
      onProgress: (done, total, name) {
        if (!mounted) return;
        setState(
          () => _uploadStatus = done >= total
              ? null
              : AppLocalizations.of(context)!.uploaderUploadingProgress(done + 1, total, name),
        );
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
    _localUrl.dispose();
    _token.dispose();
    super.dispose();
  }

  static String _trimSlash(String value) {
    var url = value.trim();
    while (url.endsWith("/")) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  void _save({bool quiet = false}) {
    _url.text = _trimSlash(_url.text);
    _localUrl.text = _trimSlash(_localUrl.text);
    FinampSetters.setUploaderUrl(_url.text);
    FinampSetters.setUploaderLocalUrl(_localUrl.text);
    FinampSetters.setUploaderToken(_token.text.trim());
    if (!quiet) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.uploaderSaved)));
      _refreshCapabilities();
    }
    setState(() {});
  }

  Future<void> _useDiscovered(DiscoveredUploader device) async {
    final messenger = ScaffoldMessenger.of(context);
    // What was found over mDNS is the home-network address. An older setup stored it as the only address; it is
    // the local one now, and the remote one is left for the server to offer (or the user to type).
    _localUrl.text = device.baseUrl;
    if (_url.text.trim() == device.baseUrl) _url.text = "";
    FinampSetters.setUploaderEnabled(true);

    if (!device.canPair) {
      _save();
      messenger.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.uploaderUsing(device.name))));
      return;
    }

    try {
      final paired = await _client.pair(device.baseUrl, "Diapason on ${_deviceName()}");
      _token.text = paired.token;
      final publicUrl = paired.publicUrl;
      if (publicUrl != null && _url.text.trim().isEmpty) _url.text = publicUrl;
      if (!mounted) return;
      _save(quiet: true);
      _refreshCapabilities();
      messenger.showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.uploaderPaired(device.name))));
    } on UploaderException catch (e) {
      if (!mounted) return;
      _save(quiet: true);
      messenger.showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.uploaderPasteTokenInstead(e.message))),
      );
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
    final l10n = AppLocalizations.of(context)!;
    try {
      await _client.openPairing();
      messenger.showSnackBar(SnackBar(content: Text(l10n.uploaderPairingOpen)));
    } on UploaderException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final policy = UploaderNetworkPolicy.fromName(ref.watch(finampSettingsProvider.uploaderNetworkPolicy));

    final proxy = ref.watch(finampSettingsProvider.uploaderYtProxy);

    final url = _url.text.trim();
    final localUrl = _localUrl.text.trim();
    final hasAddress = url.isNotEmpty || localUrl.isNotEmpty;
    final allowInsecure = ref.watch(finampSettingsProvider.uploaderAllowInsecure);
    // With both addresses set, one that the policy blocks only costs the fallback, not the whole feature.
    final reasons = [
      if (url.isNotEmpty) UploaderClient.blockReason(url, policy, allowInsecure: allowInsecure),
      if (localUrl.isNotEmpty) UploaderClient.blockReason(localUrl, policy, allowInsecure: allowInsecure),
    ];
    final blockReason = reasons.isNotEmpty && reasons.every((r) => r != null) ? reasons.first : null;
    final partialBlock = blockReason == null ? reasons.nonNulls.firstOrNull : null;
    final cleartext = url.startsWith("http://") && blockReason == null;
    final host = Uri.tryParse(url)?.host ?? "";
    // Plain HTTP to a name that doesn't look private: offer the "already secure" escape hatch.
    final offerInsecure = url.startsWith("http://") && host.isNotEmpty && !UploaderClient.isPrivateHost(host);

    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.uploaderTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Text(AppLocalizations.of(context)!.uploaderIntro),
          const SizedBox(height: 16.0),

          if (_discovery.devices.value.isNotEmpty) ...[
            Text(AppLocalizations.of(context)!.uploaderFoundOnNetwork, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4.0),
            for (final device in _discovery.devices.value)
              Card(
                margin: const EdgeInsets.only(bottom: 8.0),
                child: ListTile(
                  leading: Icon(device.canPair ? TablerIcons.link : TablerIcons.server),
                  title: Text(device.name),
                  subtitle: Text(
                    device.canPair ? AppLocalizations.of(context)!.uploaderOneTapPair(device.baseUrl) : device.baseUrl,
                  ),
                  trailing: FilledButton.tonal(
                    onPressed: () => _useDiscovered(device),
                    child: Text(
                      device.canPair
                          ? AppLocalizations.of(context)!.uploaderPair
                          : AppLocalizations.of(context)!.uploaderUse,
                    ),
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
                  Text(AppLocalizations.of(context)!.uploaderLooking, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),

          TextField(
            controller: _url,
            autocorrect: false,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context)!.uploaderRemoteAddress,
              hintText: "https://music.example.com",
              helperText: AppLocalizations.of(context)!.uploaderRemoteHelper,
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 16.0),
          TextField(
            controller: _localUrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context)!.uploaderLocalAddress,
              hintText: "http://music.local:8688",
              helperText: AppLocalizations.of(context)!.uploaderLocalHelper,
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 16.0),
          TextField(
            controller: _token,
            obscureText: !_showToken,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context)!.uploaderToken,
              suffixIcon: IconButton(
                icon: Icon(_showToken ? TablerIcons.eye_off : TablerIcons.eye),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
            ),
          ),
          const SizedBox(height: 24.0),

          Text(AppLocalizations.of(context)!.uploaderWhereMayUpload, style: Theme.of(context).textTheme.titleSmall),
          RadioListTile<UploaderNetworkPolicy>(
            contentPadding: EdgeInsets.zero,
            value: UploaderNetworkPolicy.local,
            groupValue: policy,
            title: Text(AppLocalizations.of(context)!.uploaderLocalOnly),
            subtitle: Text(AppLocalizations.of(context)!.uploaderLocalOnlySubtitle),
            onChanged: (value) => FinampSetters.setUploaderNetworkPolicy(value!.name),
          ),
          RadioListTile<UploaderNetworkPolicy>(
            contentPadding: EdgeInsets.zero,
            value: UploaderNetworkPolicy.internet,
            groupValue: policy,
            title: Text(AppLocalizations.of(context)!.uploaderAnywhere),
            subtitle: Text(AppLocalizations.of(context)!.uploaderAnywhereSubtitle),
            onChanged: (value) => FinampSetters.setUploaderNetworkPolicy(value!.name),
          ),

          if (blockReason != null)
            _notice(TablerIcons.alert_triangle, blockReason, Theme.of(context).colorScheme.error)
          else if (partialBlock != null)
            _notice(
              TablerIcons.alert_triangle,
              AppLocalizations.of(context)!.uploaderPartialBlock(partialBlock),
              Theme.of(context).colorScheme.tertiary,
            )
          else if (cleartext)
            _notice(
              TablerIcons.lock_open,
              AppLocalizations.of(context)!.uploaderCleartext,
              Theme.of(context).colorScheme.tertiary,
            ),
          if (offerInsecure)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.uploaderAlreadySecure),
              subtitle: Text(AppLocalizations.of(context)!.uploaderAlreadySecureSubtitle),
              value: allowInsecure,
              onChanged: (value) => FinampSetters.setUploaderAllowInsecure(value),
            ),

          const SizedBox(height: 24.0),
          Row(
            children: [
              Expanded(
                child: FilledButton(onPressed: _save, child: Text(AppLocalizations.of(context)!.uploaderSave)),
              ),
              const SizedBox(width: 12.0),
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _testConnection,
                  child: _testing
                      ? const SizedBox(width: 16.0, height: 16.0, child: CircularProgressIndicator(strokeWidth: 2.0))
                      : Text(AppLocalizations.of(context)!.uploaderTestConnection),
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
              label: Text(AppLocalizations.of(context)!.uploaderAllowPairing),
            ),
          ],

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(AppLocalizations.of(context)!.uploaderWifiOnly),
            subtitle: Text(AppLocalizations.of(context)!.uploaderWifiOnlySubtitle),
            value: ref.watch(finampSettingsProvider.uploaderWifiOnly),
            onChanged: (value) => FinampSetters.setUploaderWifiOnly(value),
          ),

          const SizedBox(height: 32.0),
          Text(AppLocalizations.of(context)!.uploaderFromDevice, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4.0),
          Text(AppLocalizations.of(context)!.uploaderFromDeviceBody),
          const SizedBox(height: 8.0),
          OutlinedButton.icon(
            onPressed: _uploadStatus != null || blockReason != null || !hasAddress ? null : _pickAndUpload,
            icon: const Icon(TablerIcons.upload),
            label: Text(AppLocalizations.of(context)!.uploaderChooseFiles),
          ),
          if (_uploadStatus != null) ...[
            const SizedBox(height: 8.0),
            const LinearProgressIndicator(),
            const SizedBox(height: 4.0),
            Text(
              _uploadStatus!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],

          const SizedBox(height: 32.0),
          Text(AppLocalizations.of(context)!.uploaderYoutubeSection, style: Theme.of(context).textTheme.titleSmall),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(AppLocalizations.of(context)!.uploaderYoutubeSwitch),
            subtitle: Text(
              _caps == null || (_caps!.reachable && _caps!.ytdlp)
                  ? AppLocalizations.of(context)!.uploaderYoutubeOk
                  : !_caps!.reachable
                  ? AppLocalizations.of(
                      context,
                    )!.uploaderYoutubeUnavailable(_caps!.problem ?? AppLocalizations.of(context)!.uploaderUnreachable)
                  : AppLocalizations.of(context)!.uploaderYoutubeOff,
            ),
            value: proxy,
            onChanged: blockReason == null && hasAddress
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
