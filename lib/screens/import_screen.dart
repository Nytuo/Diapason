import 'dart:io';

import 'package:diapason/services/transfer/desktop_transfer_service.dart';
import 'package:diapason/services/transfer/import_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  static const routeName = "/import";

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  DesktopTransferService get _transfer => GetIt.instance<DesktopTransferService>();

  bool _importingFiles = false;

  @override
  void initState() {
    super.initState();
    _transfer.startScan();
  }

  @override
  void dispose() {
    _transfer.stopScan();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.audio,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() => _importingFiles = true);
    final files = result.files.map((f) => f.path).nonNulls.map(File.new);
    final imported = await GetIt.instance<ImportService>().importFiles(files);

    if (!mounted) return;
    setState(() => _importingFiles = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(imported == 0 ? "Nothing imported" : "Imported $imported file(s)")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Import music")),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          const Text(
            "Imported music is copied into Diapason's own folder and appears in your library as a local source. "
            "The originals are left where they are.",
          ),
          const SizedBox(height: 24.0),

          Text("From this device", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8.0),
          FilledButton.icon(
            onPressed: _importingFiles ? null : _pickFiles,
            icon: _importingFiles
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(TablerIcons.file_import),
            label: const Text("Choose files"),
          ),

          const Divider(height: 48.0),

          Text("From Diapason desktop", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4.0),
          const Text(
            "The desktop app must be open on the same network, offering files.",
            style: TextStyle(fontSize: 12.0),
          ),
          const SizedBox(height: 12.0),

          ValueListenableBuilder<TransferState>(
            valueListenable: _transfer.state,
            builder: (context, state, _) {
              return switch (state) {
                TransferImporting(message: final message) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  title: Text(message),
                ),
                TransferDone(count: final count) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(TablerIcons.circle_check),
                  title: Text(count == 0 ? "Nothing to import" : "Imported $count file(s)"),
                ),
                TransferFailed(message: final message) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(TablerIcons.alert_circle, color: Theme.of(context).colorScheme.error),
                  title: Text(message),
                ),
                TransferIdle() => const SizedBox.shrink(),
              };
            },
          ),

          ValueListenableBuilder<List<DesktopPeer>>(
            valueListenable: _transfer.peers,
            builder: (context, peers, _) {
              if (peers.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: Text("Looking for the desktop app…"),
                );
              }
              return Column(
                children: [
                  for (final peer in peers)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(TablerIcons.device_desktop),
                      title: Text(peer.name),
                      subtitle: Text(Uri.parse(peer.url).host),
                      trailing: const Icon(TablerIcons.download),
                      onTap: () => _transfer.importFrom(peer),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
