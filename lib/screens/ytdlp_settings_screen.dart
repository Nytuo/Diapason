import 'package:diapason/components/YtDlp/ytdlp_install_dialog.dart';
import 'package:diapason/screens/uploader_settings_screen.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Settings → YouTube (yt-dlp): installing and updating the local yt-dlp, and
/// tweaking how it's run — with friendly controls, or as a raw command line.
class YtDlpSettingsScreen extends StatefulWidget {
  const YtDlpSettingsScreen({super.key});

  static const routeName = "/settings/ytdlp";

  @override
  State<YtDlpSettingsScreen> createState() => _YtDlpSettingsScreenState();
}

class _YtDlpSettingsScreenState extends State<YtDlpSettingsScreen> {
  static final _log = Logger("YtDlpSettingsScreen");

  final _service = GetIt.instance<LocalYtDlpService>();
  final _availability = GetIt.instance<YouTubeAvailability>();

  late YtDlpConfig _cfg = _service.config.value.clone();
  bool _dirty = false;
  bool _busy = false;
  String? _testResult;
  bool _testOk = false;

  late final _custom = TextEditingController(text: _cfg.customBinaryPath);
  late final _proxy = TextEditingController(text: _cfg.proxy);
  late final _cookiesFile = TextEditingController(text: _cfg.cookiesFile);
  late final _rate = TextEditingController(text: _cfg.rateLimit);
  late final _geo = TextEditingController(text: _cfg.geoBypassCountry);
  late final _extractor = TextEditingController(text: _cfg.extractorArgs);
  late final _extra = TextEditingController(text: _cfg.extraArgs);
  late final _advanced = TextEditingController(text: _cfg.advancedArgs);

  static const _browsers = ["", "chrome", "firefox", "safari", "edge", "brave", "chromium", "opera", "vivaldi"];

  @override
  void initState() {
    super.initState();
    _service.status.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.status.removeListener(_rebuild);
    for (final c in [_custom, _proxy, _cookiesFile, _rate, _geo, _extractor, _extra, _advanced]) {
      c.dispose();
    }
    super.dispose();
  }

  void _change(void Function() mutate) => setState(() {
    mutate();
    _dirty = true;
  });

  /// Copies the text fields into the config being edited.
  void _collect() {
    _cfg
      ..customBinaryPath = _custom.text.trim()
      ..proxy = _proxy.text.trim()
      ..cookiesFile = _cookiesFile.text.trim()
      ..rateLimit = _rate.text.trim()
      ..geoBypassCountry = _geo.text.trim()
      ..extractorArgs = _extractor.text.trim()
      ..extraArgs = _extra.text.trim()
      ..advancedArgs = _advanced.text;
  }

  Future<void> _save() async {
    _collect();
    setState(() => _busy = true);
    try {
      await _service.saveConfig(_cfg);
      await _availability.refresh();
      if (mounted) {
        setState(() => _dirty = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("yt-dlp settings saved")));
      }
    } catch (e, stack) {
      _toast(FriendlyError.report(_log, "Saving yt-dlp settings", e, stack));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _install({bool updateOnly = false}) async {
    final installed = await showYtDlpInstallDialog(context, updateOnly: updateOnly);
    if (installed) await _availability.refresh();
  }

  Future<void> _checkUpdates() async {
    setState(() => _busy = true);
    try {
      await _service.checkForUpdate();
      final s = _service.status.value;
      _toast(
        s.latestVersion == null
            ? "Couldn't reach GitHub to check for updates."
            : s.updateAvailable
            ? "yt-dlp ${s.latestVersion} is available."
            : "yt-dlp is up to date (${s.version}).",
      );
    } catch (e, stack) {
      _toast(FriendlyError.report(_log, "Checking for yt-dlp updates", e, stack));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Remove the downloaded yt-dlp?"),
        content: const Text(
          "This deletes the copy Diapason downloaded (and its Deno). A yt-dlp you installed yourself is left alone. "
          "YouTube will stop working here until you set it up again.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text("Remove")),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.installer.removeManaged();
      await _service.refresh();
      await _availability.refresh();
    } catch (e, stack) {
      _toast(FriendlyError.report(_log, "Removing yt-dlp", e, stack));
    }
  }

  Future<void> _test() async {
    _collect();
    if (_dirty) await _save();
    setState(() {
      _busy = true;
      _testResult = null;
    });
    try {
      final result = await _service.selfTest();
      setState(() {
        _testOk = true;
        _testResult = result;
      });
    } catch (e, stack) {
      final d = FriendlyError.describe(e);
      _log.warning("yt-dlp self-test failed: ${d.technical}", e, stack);
      setState(() {
        _testOk = false;
        _testResult = "${d.message}\n\n${d.technical}";
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickBinary() async {
    final picked = await FilePicker.pickFiles(dialogTitle: "Choose your yt-dlp executable");
    final path = picked?.files.single.path;
    if (path != null) {
      _custom.text = path;
      _change(() {});
    }
  }

  Future<void> _pickCookies() async {
    final picked = await FilePicker.pickFiles(dialogTitle: "Choose a cookies.txt file");
    final path = picked?.files.single.path;
    if (path != null) {
      _cookiesFile.text = path;
      _change(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text("YouTube (yt-dlp)")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            "Diapason uses yt-dlp for everything YouTube — search, playback and recommendations. It can run on "
            "this computer or on your diapason-uploader, and unlike a built-in library it updates itself whenever "
            "YouTube changes.",
          ),
          const SizedBox(height: 16),
          _routeCard(theme),
          const SizedBox(height: 8),
          ..._inApp(theme),
          if (LocalYtDlpService.supported) ...[
            const SizedBox(height: 16),
            _statusCard(theme),
            const SizedBox(height: 8),
            _actions(),
            const Divider(height: 32),
            ..._visual(theme),
            const Divider(height: 32),
            ..._advancedSection(theme),
            const SizedBox(height: 16),
            _testSection(theme),
            const SizedBox(height: 24),
            FilledButton(onPressed: _dirty && !_busy ? _save : null, child: const Text("Save settings")),
            const SizedBox(height: 24),
          ] else ...[
            const SizedBox(height: 16),
            Text(
              YtDlpPaths.execBlockedReason ??
                  "This device can't run yt-dlp itself, so YouTube works through your diapason-uploader. "
                      "Connect one with its YouTube feature turned on.",
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pushNamed(UploaderSettingsScreen.routeName),
              icon: const Icon(TablerIcons.cloud_upload),
              label: const Text("Uploader settings"),
            ),
          ],
        ],
      ),
    );
  }

  /// How YouTube behaves inside the app — applies on every platform, whichever route is used.
  List<Widget> _inApp(ThemeData theme) {
    final s = FinampSettingsHelper.finampSettings;
    return [
      const SizedBox(height: 8),
      Text("In the app", style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("Search YouTube first"),
        subtitle: const Text("When you search, start on the YouTube results instead of your library."),
        value: s.youtubeSearchByDefault,
        onChanged: (v) => setState(() => FinampSetters.setYoutubeSearchByDefault(v)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("“Hits on YouTube” shelf"),
        subtitle: const Text("YouTube's music chart on the YouTube home page."),
        value: s.youtubeShowHits,
        onChanged: (v) => setState(() => FinampSetters.setYoutubeShowHits(v)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("“New this week” shelf"),
        subtitle: const Text("Fresh uploads on the YouTube home page."),
        value: s.youtubeShowNew,
        onChanged: (v) => setState(() => FinampSetters.setYoutubeShowNew(v)),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text("Search results: ${s.youtubeResultCount}"),
        subtitle: Slider(
          value: s.youtubeResultCount.toDouble().clamp(10, 50),
          min: 10,
          max: 50,
          divisions: 8,
          label: "${s.youtubeResultCount}",
          onChanged: (v) => setState(() => FinampSetters.setYoutubeResultCount(v.round())),
        ),
      ),
    ];
  }

  Widget _routeCard(ThemeData theme) {
    final status = _availability.status.value;
    final (IconData icon, String title, String body) = switch (status.source) {
      YouTubeSource.local => (TablerIcons.circle_check, "YouTube is on", "Using yt-dlp on this computer."),
      YouTubeSource.uploader => (
        TablerIcons.circle_check,
        "YouTube is on",
        "Using the yt-dlp on your uploader${status.uploader.ytdlpVersion != null ? " (${status.uploader.ytdlpVersion})" : ""}.",
      ),
      YouTubeSource.none => (TablerIcons.circle_x, "YouTube is off", status.problems.join("\n")),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: status.available ? Colors.green.shade600 : theme.colorScheme.error),
        title: Text(title),
        subtitle: Text(body),
        trailing: IconButton(
          icon: const Icon(TablerIcons.refresh),
          tooltip: "Check again",
          onPressed: () => _availability.refresh(),
        ),
      ),
    );
  }

  Widget _statusCard(ThemeData theme) {
    final s = _service.status.value;
    final lines = <String>[];
    switch (s.state) {
      case LocalYtDlpState.checking:
        lines.add("Checking…");
      case LocalYtDlpState.notInstalled:
        lines.add("yt-dlp wasn't found on this computer.");
      case LocalYtDlpState.broken:
        lines.add(s.problem ?? "yt-dlp is installed but won't run.");
      case LocalYtDlpState.ready:
        lines.add("yt-dlp ${s.version}");
        lines.add(switch (s.origin) {
          YtDlpOrigin.managed => "Managed by Diapason (updates automatically)",
          YtDlpOrigin.custom => "Your own copy: ${s.path}",
          _ => "Found on your system: ${s.path}",
        });
        if (s.updateAvailable) lines.add("Update available: ${s.latestVersion}");
      case LocalYtDlpState.unsupported:
        break;
    }
    lines.add(
      s.jsRuntime == null
          ? "JavaScript runtime: none — some videos may fail. Install Deno below."
          : "JavaScript runtime: ${s.jsRuntime}${s.jsRuntimeManaged ? " (managed by Diapason)" : " (${s.jsRuntimePath})"}",
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("On this computer", style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final l in lines) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(l)),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    final s = _service.status.value;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (s.state == LocalYtDlpState.notInstalled || s.state == LocalYtDlpState.broken)
          FilledButton.icon(
            onPressed: _busy ? null : () => _install(),
            icon: const Icon(TablerIcons.download),
            label: const Text("Install yt-dlp"),
          ),
        if (s.isReady && s.updateAvailable)
          FilledButton.icon(
            onPressed: _busy ? null : () => _install(updateOnly: true),
            icon: const Icon(TablerIcons.arrow_up_circle),
            label: Text("Update to ${s.latestVersion}"),
          ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _checkUpdates,
          icon: const Icon(TablerIcons.refresh),
          label: const Text("Check for updates"),
        ),
        if (s.jsRuntime == null || !s.jsRuntimeManaged)
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _install(),
            icon: const Icon(TablerIcons.brand_javascript),
            label: Text(s.jsRuntime == null ? "Install Deno" : "Install managed Deno"),
          ),
        if (s.origin == YtDlpOrigin.managed || s.jsRuntimeManaged)
          TextButton.icon(
            onPressed: _busy ? null : _remove,
            icon: const Icon(TablerIcons.trash),
            label: const Text("Remove downloaded copy"),
          ),
      ],
    );
  }

  List<Widget> _visual(ThemeData theme) {
    return [
      Text("Behaviour", style: theme.textTheme.titleMedium),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("Keep yt-dlp up to date"),
        subtitle: const Text("Checks once a day and updates the copy Diapason manages."),
        value: _cfg.autoUpdate,
        onChanged: (v) => _change(() => _cfg.autoUpdate = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("Prefer my uploader's yt-dlp"),
        subtitle: const Text("Use the one on your server even when this computer has its own."),
        value: _cfg.preferUploader,
        onChanged: (v) => _change(() => _cfg.preferUploader = v),
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<YtAudioPreference>(
        initialValue: _cfg.audio,
        decoration: const InputDecoration(labelText: "Audio format"),
        items: [for (final a in YtAudioPreference.values) DropdownMenuItem(value: a, child: Text(a.label))],
        onChanged: (v) => _change(() => _cfg.audio = v ?? _cfg.audio),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        initialValue: const ["auto", "deno", "node", "bun", "none"].contains(_cfg.jsRuntime) ? _cfg.jsRuntime : "auto",
        decoration: const InputDecoration(labelText: "JavaScript runtime"),
        items: const [
          DropdownMenuItem(value: "auto", child: Text("Automatic (Deno, then Node, then Bun)")),
          DropdownMenuItem(value: "deno", child: Text("Deno")),
          DropdownMenuItem(value: "node", child: Text("Node.js")),
          DropdownMenuItem(value: "bun", child: Text("Bun")),
          DropdownMenuItem(value: "none", child: Text("None")),
        ],
        onChanged: (v) => _change(() => _cfg.jsRuntime = v ?? "auto"),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _custom,
        onChanged: (_) => _change(() {}),
        decoration: InputDecoration(
          labelText: "Use this yt-dlp executable (optional)",
          hintText: "Leave empty to use the managed or system one",
          suffixIcon: IconButton(icon: const Icon(TablerIcons.folder_open), onPressed: _pickBinary),
        ),
      ),
      const SizedBox(height: 24),
      Text("Network", style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      TextField(
        controller: _proxy,
        onChanged: (_) => _change(() {}),
        decoration: const InputDecoration(labelText: "Proxy", hintText: "socks5://127.0.0.1:1080"),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _rate,
              onChanged: (_) => _change(() {}),
              decoration: const InputDecoration(labelText: "Speed limit", hintText: "e.g. 2M"),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _geo,
              onChanged: (_) => _change(() {}),
              maxLength: 2,
              decoration: const InputDecoration(labelText: "Pretend to be in…", hintText: "US", counterText: ""),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _stepper(
              "Timeout (s)",
              _cfg.socketTimeoutSecs,
              5,
              120,
              (v) => _change(() => _cfg.socketTimeoutSecs = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _stepper("Retries", _cfg.retries, 0, 20, (v) => _change(() => _cfg.retries = v))),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("Force IPv4"),
        subtitle: const Text("Helps on networks where IPv6 to YouTube is flaky."),
        value: _cfg.forceIpv4,
        onChanged: (v) => _change(() => _cfg.forceIpv4 = v),
      ),
      const SizedBox(height: 16),
      Text("Signing in (for blocked or age-restricted videos)", style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: _browsers.contains(_cfg.cookiesFromBrowser) ? _cfg.cookiesFromBrowser : "",
        decoration: const InputDecoration(
          labelText: "Borrow cookies from a browser",
          helperText: "yt-dlp reads your YouTube login from it. Nothing is sent anywhere except to YouTube.",
        ),
        items: [for (final b in _browsers) DropdownMenuItem(value: b, child: Text(b.isEmpty ? "Don't" : b))],
        onChanged: (v) => _change(() => _cfg.cookiesFromBrowser = v ?? ""),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _cookiesFile,
        onChanged: (_) => _change(() {}),
        decoration: InputDecoration(
          labelText: "…or a cookies.txt file",
          suffixIcon: IconButton(icon: const Icon(TablerIcons.folder_open), onPressed: _pickCookies),
        ),
      ),
    ];
  }

  Widget _stepper(String label, int value, int min, int max, ValueChanged<int> onChanged) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(TablerIcons.minus),
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          Expanded(child: Text("$value", textAlign: TextAlign.center)),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(TablerIcons.plus),
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }

  List<Widget> _advancedSection(ThemeData theme) {
    _collect();
    final preview = _service.previewCommand(["--no-playlist", "-f", _cfg.audio.format, "-g", "--", "<youtube link>"]);
    // Show what the CURRENT edit would run, not what's saved.
    final shown = _previewFor(_cfg);
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text("Advanced mode", style: theme.textTheme.titleMedium),
        subtitle: const Text("Write the yt-dlp flags yourself instead of using the controls above."),
        value: _cfg.advancedMode,
        onChanged: (v) => _change(() {
          _cfg.advancedMode = v;
          if (v && _advanced.text.trim().isEmpty) {
            _advanced.text = _cfg.visualAsCommandLine();
          }
        }),
      ),
      if (_cfg.advancedMode) ...[
        TextField(
          controller: _advanced,
          onChanged: (_) => _change(() {}),
          minLines: 3,
          maxLines: 8,
          style: const TextStyle(fontFamily: "monospace"),
          decoration: const InputDecoration(
            labelText: "Flags passed to every yt-dlp run",
            helperText:
                "Quote values with spaces. Diapason adds the search/stream/URL part and the JavaScript runtime.",
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => _change(() => _advanced.text = _cfg.visualAsCommandLine()),
            child: const Text("Reset from the controls above"),
          ),
        ),
      ] else ...[
        TextField(
          controller: _extractor,
          onChanged: (_) => _change(() {}),
          decoration: const InputDecoration(labelText: "Extractor arguments", hintText: "youtube:player_client=tv"),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _extra,
          onChanged: (_) => _change(() {}),
          decoration: const InputDecoration(labelText: "Extra flags", hintText: "--no-check-certificates"),
        ),
      ],
      const SizedBox(height: 12),
      Text("Command that will run", style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                shown.isEmpty ? preview : shown,
                style: const TextStyle(fontFamily: "monospace", fontSize: 12),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: "Copy",
              icon: const Icon(TablerIcons.copy, size: 18),
              onPressed: () => Clipboard.setData(ClipboardData(text: shown)),
            ),
          ],
        ),
      ),
    ];
  }

  String _previewFor(YtDlpConfig cfg) {
    final s = _service.status.value;
    final args = [
      "--no-warnings",
      "--no-colors",
      ...cfg.globalArgs(),
      if (s.jsRuntime != null && s.jsRuntimePath != null) ...["--js-runtimes", "${s.jsRuntime}:${s.jsRuntimePath}"],
      "--no-playlist",
      "-f",
      cfg.audio.format,
      "--print",
      "%(url)s",
      "--",
      "<youtube link>",
    ];
    return "${s.path ?? "yt-dlp"} ${YtDlpConfig.joinArgs(args)}";
  }

  Widget _testSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _test,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(TablerIcons.player_play),
          label: const Text("Test with a real video"),
        ),
        if (_testResult != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _testOk ? TablerIcons.circle_check : TablerIcons.circle_x,
                  color: _testOk ? Colors.green.shade600 : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(child: SelectableText(_testResult!)),
              ],
            ),
          ),
      ],
    );
  }
}
