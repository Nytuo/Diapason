import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/media_source_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

({IconData icon, String label, String hint}) sourceKindPresentation(MediaSourceKind kind) => switch (kind) {
  MediaSourceKind.jellyfin => (icon: TablerIcons.server, label: "Jellyfin", hint: "https://jellyfin.example.com"),
  MediaSourceKind.subsonic => (
    icon: TablerIcons.broadcast,
    label: "Subsonic / Navidrome",
    hint: "https://navidrome.example.com",
  ),
  MediaSourceKind.plex => (icon: TablerIcons.player_play, label: "Plex", hint: "http://192.168.1.10:32400"),
  MediaSourceKind.local => (icon: TablerIcons.folder, label: "Local files", hint: "Choose a music folder"),
  MediaSourceKind.youtube => (icon: TablerIcons.brand_youtube, label: "YouTube", hint: ""),
};

class SourceForm extends StatefulWidget {
  const SourceForm({super.key, required this.kind, required this.onSaved, this.existing, this.saveLabel});

  final MediaSourceKind kind;

  final MediaSourceConfig? existing;

  final void Function(MediaSourceConfig config) onSaved;
  final String? saveLabel;

  @override
  State<SourceForm> createState() => _SourceFormState();
}

class _SourceFormState extends State<SourceForm> {
  final _formKey = GlobalKey<FormState>();

  late final _name = TextEditingController(text: widget.existing?.name ?? "");
  late final _address = TextEditingController(text: widget.existing?.publicAddress ?? "");
  late final _username = TextEditingController(text: widget.existing?.username ?? "");
  late final _password = TextEditingController(text: widget.existing?.password ?? "");
  late final _token = TextEditingController(text: widget.existing?.accessToken ?? "");
  late final _localNetworkAddress = TextEditingController(text: widget.existing?.localAddress ?? "");
  late bool _preferLocalNetwork = widget.existing?.preferLocalNetwork ?? false;
  late String _localPath = widget.existing?.localPath ?? "";

  bool _testing = false;

  bool? _reachable;

  bool get _isLocal => widget.kind == MediaSourceKind.local;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _username.dispose();
    _password.dispose();
    _token.dispose();
    _localNetworkAddress.dispose();
    super.dispose();
  }

  MediaSourceConfig _buildConfig() {
    final service = GetIt.instance<MediaSourceService>();
    final fallbackName = _isLocal
        ? (_localPath.split(RegExp(r"[/\\]")).lastWhere((s) => s.isNotEmpty, orElse: () => "Local"))
        : (Uri.tryParse(_address.text.trim())?.host ?? sourceKindPresentation(widget.kind).label);

    return MediaSourceConfig(
      sourceId: widget.existing?.sourceId ?? service.newSourceId(widget.kind),
      kind: widget.kind,
      name: _name.text.trim().isEmpty ? fallbackName : _name.text.trim(),
      publicAddress: _isLocal ? "" : _normalizeUrl(_address.text),
      localAddress: _isLocal ? "" : _normalizeUrl(_localNetworkAddress.text),
      preferLocalNetwork: !_isLocal && _preferLocalNetwork,
      isLocal: widget.existing?.isLocal ?? false,
      username: _username.text.trim(),
      password: _password.text,
      accessToken: _token.text.trim(),
      localPath: _localPath,
      enabled: widget.existing?.enabled ?? true,
    );
  }

  static String _normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith("http://") && !url.startsWith("https://")) url = "https://$url";
    while (url.endsWith("/")) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath();
    if (path != null) setState(() => _localPath = path);
  }

  Future<void> _test() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _reachable = null;
    });
    final ok = await GetIt.instance<MediaSourceService>().testConnection(_buildConfig());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _reachable = ok;
    });
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    widget.onSaved(_buildConfig());
  }

  @override
  Widget build(BuildContext context) {
    final presentation = sourceKindPresentation(widget.kind);

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: "Name (optional)",
              helperText: "How this source is labelled in your library",
            ),
          ),
          const SizedBox(height: 16.0),

          if (_isLocal) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(TablerIcons.folder),
              title: Text(_localPath.isEmpty ? presentation.hint : _localPath),
              trailing: const Icon(TablerIcons.dots),
              onTap: _pickFolder,
            ),
            if (_localPath.isEmpty)
              Text(
                "Choose a folder to scan",
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12.0),
              ),
          ] else ...[
            TextFormField(
              controller: _address,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(labelText: "Server address", hintText: presentation.hint),
              validator: (v) => (v == null || v.trim().isEmpty) ? "A server address is required" : null,
            ),
            const SizedBox(height: 16.0),

            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text("Local network address (optional)"),
              subtitle: const Text("Switch to a faster address automatically when on this network"),
              childrenPadding: const EdgeInsets.only(bottom: 8.0),
              children: [
                TextFormField(
                  controller: _localNetworkAddress,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: "Local network address",
                    hintText: "http://192.168.1.10:4533",
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _preferLocalNetwork,
                  title: const Text("Prefer local network when available"),
                  onChanged: (value) => setState(() => _preferLocalNetwork = value ?? false),
                ),
              ],
            ),
            const SizedBox(height: 8.0),

            if (widget.kind == MediaSourceKind.subsonic) ...[
              TextFormField(
                controller: _username,
                autocorrect: false,
                decoration: const InputDecoration(labelText: "Username"),
                validator: (v) => (v == null || v.trim().isEmpty) ? "A username is required" : null,
              ),
              const SizedBox(height: 16.0),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "Password",
                  helperText: "Subsonic signs every request, so the password is stored on this device",
                ),
                validator: (v) => (v == null || v.isEmpty) ? "A password is required" : null,
              ),
            ],

            if (widget.kind == MediaSourceKind.plex)
              TextFormField(
                controller: _token,
                autocorrect: false,
                decoration: const InputDecoration(labelText: "Plex token", helperText: "X-Plex-Token"),
                validator: (v) => (v == null || v.trim().isEmpty) ? "A Plex token is required" : null,
              ),
          ],

          const SizedBox(height: 24.0),

          if (_reachable != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: Row(
                children: [
                  Icon(
                    _reachable! ? TablerIcons.circle_check : TablerIcons.alert_circle,
                    color: _reachable!
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8.0),
                  Expanded(
                    child: Text(
                      _reachable!
                          ? "Connected"
                          : "Couldn't reach this source. Check the address and credentials.",
                    ),
                  ),
                ],
              ),
            ),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing || (_isLocal && _localPath.isEmpty) ? null : _test,
                  icon: _testing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(TablerIcons.plug_connected),
                  label: const Text("Test"),
                ),
              ),
              const SizedBox(width: 12.0),
              Expanded(
                child: FilledButton(
                  onPressed: (_isLocal && _localPath.isEmpty) ? null : _save,
                  child: Text(widget.saveLabel ?? "Save"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
