import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/ytdlp_installer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Offers to download yt-dlp (and Deno, the JavaScript runtime it needs for
/// YouTube) and shows the installation as it happens.
///
/// Returns true if something was installed.
Future<bool> showYtDlpInstallDialog(
  BuildContext context, {
  bool updateOnly = false,
  bool startImmediately = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _InstallDialog(updateOnly: updateOnly, startImmediately: startImmediately),
  );
  return result ?? false;
}

class _InstallDialog extends StatefulWidget {
  const _InstallDialog({required this.updateOnly, required this.startImmediately});

  final bool updateOnly;
  final bool startImmediately;

  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

enum _Phase { offer, installing, done, failed }

class _InstallDialogState extends State<_InstallDialog> {
  static final _log = Logger("YtDlpInstallDialog");

  final _service = GetIt.instance<LocalYtDlpService>();
  _Phase _phase = _Phase.offer;
  bool _withJs = true;
  List<InstallStep> _steps = const [];
  InstallCancel? _cancel;
  String? _error;
  String? _technical;
  bool _showTechnical = false;
  String? _summary;

  @override
  void initState() {
    super.initState();
    _withJs = _service.status.value.jsRuntime == null || widget.updateOnly == false;
    if (_service.status.value.jsRuntime != null && !_service.status.value.jsRuntimeManaged) _withJs = false;
    if (widget.startImmediately) WidgetsBinding.instance.addPostFrameCallback((_) => _install());
  }

  Future<void> _install() async {
    final cancel = InstallCancel();
    setState(() {
      _phase = _Phase.installing;
      _cancel = cancel;
      _error = null;
      _technical = null;
    });
    _log.info("Installing yt-dlp (js runtime: $_withJs)");
    try {
      await _service.installer.install(
        ytdlp: true,
        jsRuntime: _withJs,
        cancel: cancel,
        onUpdate: (steps) {
          if (mounted) setState(() => _steps = steps);
        },
      );
      await _service.refresh();
      final s = _service.status.value;
      if (!mounted) return;
      setState(() {
        _phase = _Phase.done;
        _summary = "yt-dlp ${s.version ?? ""}${s.jsRuntime != null ? " · ${s.jsRuntime}" : ""}".trim();
      });
    } on InstallCancelled {
      if (mounted) Navigator.of(context).pop(false);
    } catch (e, stack) {
      final d = FriendlyError.describe(e);
      _log.warning("yt-dlp install failed: ${d.technical}", e, stack);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = d.message;
        _technical = d.technical;
      });
    }
  }

  Future<void> _useExisting() async {
    final picked = await FilePicker.pickFiles(dialogTitle: "Choose your yt-dlp executable");
    final path = picked?.files.single.path;
    if (path == null) return;
    final cfg = _service.config.value.clone()..customBinaryPath = path;
    await _service.saveConfig(cfg);
    if (!mounted) return;
    if (_service.status.value.isReady) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _phase = _Phase.failed;
        _error = _service.status.value.problem ?? "That file doesn't look like a working yt-dlp.";
        _technical = path;
      });
    }
  }

  Future<void> _dontAsk() async {
    final cfg = _service.config.value.clone()..promptDismissed = true;
    await _service.saveConfig(cfg);
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      icon: const Icon(TablerIcons.brand_youtube, size: 32),
      title: Text(switch (_phase) {
        _Phase.offer => widget.updateOnly ? "Update yt-dlp" : "Set up YouTube on this computer",
        _Phase.installing => "Installing…",
        _Phase.done => "All set",
        _Phase.failed => "Installation didn't finish",
      }),
      content: SizedBox(width: 460, child: _content(context)),
      actions: _actions(context),
    );
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    switch (_phase) {
      case _Phase.offer:
        final s = _service.status.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Diapason uses yt-dlp to search and play YouTube, and it updates far faster than the app can. "
              "I can download it for you and keep it up to date — it lives in Diapason's own folder and "
              "nothing else on your computer is touched.",
            ),
            const SizedBox(height: 12),
            _bullet(TablerIcons.download, "yt-dlp (≈ 35 MB) from github.com/yt-dlp/yt-dlp"),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _withJs,
              onChanged: (v) => setState(() => _withJs = v ?? false),
              title: const Text("Deno (≈ 40 MB) from github.com/denoland/deno"),
              subtitle: Text(
                s.jsRuntime != null && !s.jsRuntimeManaged
                    ? "You already have ${s.jsRuntime} — Diapason can use that instead."
                    : "A JavaScript runtime yt-dlp needs to read YouTube. Recommended.",
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "Downloads are checked against the SHA-256 published by each project before they're used.",
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      case _Phase.installing:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final step in _steps) _stepTile(context, step)],
        );
      case _Phase.done:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("YouTube is ready on this computer.\n${_summary ?? ""}"),
            if (_service.status.value.jsRuntime == null) ...[
              const SizedBox(height: 8),
              Text(
                "No JavaScript runtime was found, so some videos may not play. You can install Deno from the yt-dlp settings.",
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        );
      case _Phase.failed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_error ?? "Something went wrong."),
            if (_steps.isNotEmpty) ...[const SizedBox(height: 12), for (final step in _steps) _stepTile(context, step)],
            if (_technical != null) ...[
              TextButton(
                onPressed: () => setState(() => _showTechnical = !_showTechnical),
                child: Text(_showTechnical ? "Hide technical details" : "Technical details"),
              ),
              if (_showTechnical) SelectableText(_technical!, style: theme.textTheme.bodySmall),
            ],
          ],
        );
    }
  }

  Widget _bullet(IconData icon, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );

  Widget _stepTile(BuildContext context, InstallStep step) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (step.state) {
      InstallStepState.pending => Icon(TablerIcons.circle, size: 18, color: scheme.outline),
      InstallStepState.running => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      InstallStepState.done => Icon(TablerIcons.circle_check, size: 18, color: Colors.green.shade600),
      InstallStepState.skipped => Icon(TablerIcons.circle_dashed, size: 18, color: scheme.outline),
      InstallStepState.failed => Icon(TablerIcons.circle_x, size: 18, color: scheme.error),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: icon),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.label),
                if (step.state == InstallStepState.running && step.progress != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: LinearProgressIndicator(value: step.progress),
                  ),
                if (step.note != null)
                  Text(
                    step.note!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: step.state == InstallStepState.failed ? scheme.error : null),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    switch (_phase) {
      case _Phase.offer:
        return [
          if (!widget.updateOnly) TextButton(onPressed: _useExisting, child: const Text("I have yt-dlp…")),
          if (!widget.updateOnly) TextButton(onPressed: _dontAsk, child: const Text("Don't ask again")),
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text("Not now")),
          FilledButton(onPressed: _install, child: Text(widget.updateOnly ? "Update" : "Install")),
        ];
      case _Phase.installing:
        return [TextButton(onPressed: () => _cancel?.cancel(), child: const Text("Cancel"))];
      case _Phase.done:
        return [FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text("Done"))];
      case _Phase.failed:
        return [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text("Close")),
          FilledButton(onPressed: _install, child: const Text("Try again")),
        ];
    }
  }
}
