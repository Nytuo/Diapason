import 'dart:async';
import 'dart:convert';

import 'package:diapason/services/transfer/import_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:nsd/nsd.dart' as nsd;

class DesktopPeer {
  const DesktopPeer({required this.name, required this.url});

  final String name;
  final String url;

  @override
  bool operator ==(Object other) => other is DesktopPeer && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

sealed class TransferState {
  const TransferState();
}

class TransferIdle extends TransferState {
  const TransferIdle();
}

class TransferImporting extends TransferState {
  const TransferImporting(this.message);

  final String message;
}

class TransferDone extends TransferState {
  const TransferDone(this.count);

  final int count;
}

class TransferFailed extends TransferState {
  const TransferFailed(this.message);

  final String message;
}

class DesktopTransferService {
  DesktopTransferService({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("DesktopTransferService");
  static const serviceType = "_diapason._tcp";

  final http.Client _http;

  nsd.Discovery? _discovery;

  final ValueNotifier<List<DesktopPeer>> peers = ValueNotifier(const []);
  final ValueNotifier<bool> isScanning = ValueNotifier(false);
  final ValueNotifier<TransferState> state = ValueNotifier(const TransferIdle());

  Future<void> startScan() async {
    await stopScan();
    peers.value = const [];
    isScanning.value = true;

    try {
      final discovery = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.v4);
      _discovery = discovery;
      discovery.addListener(() {
        peers.value = discovery.services.map(_toPeer).nonNulls.toList();
      });
    } catch (e) {
      _log.warning("Could not browse for desktop instances: $e");
      isScanning.value = false;
    }
  }

  Future<void> stopScan() async {
    isScanning.value = false;
    if (_discovery == null) return;
    try {
      await nsd.stopDiscovery(_discovery!);
    } catch (_) {}
    _discovery = null;
  }

  DesktopPeer? _toPeer(nsd.Service service) {
    final host = service.host;
    final port = service.port;
    if (host == null || port == null) return null;

    final normalized = host.endsWith(".") ? host.substring(0, host.length - 1) : host;
    return DesktopPeer(name: service.name ?? "Diapason Desktop", url: "http://$normalized:$port");
  }

  Future<void> importFrom(DesktopPeer peer) async {
    state.value = TransferImporting("Connecting to ${peer.name}…");

    try {
      final manifest = await _http.get(Uri.parse("${peer.url}/list")).timeout(const Duration(seconds: 10));
      if (manifest.statusCode != 200) {
        state.value = TransferFailed("${peer.name} returned HTTP ${manifest.statusCode}");
        return;
      }

      final body = jsonDecode(utf8.decode(manifest.bodyBytes)) as Map<String, dynamic>;
      final files = (body["files"] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? const [];
      if (files.isEmpty) {
        state.value = const TransferDone(0);
        return;
      }

      final importer = GetIt.instance<ImportService>();
      var imported = 0;

      for (final (index, file) in files.indexed) {
        final name = (file["name"] ?? "track_$index.mp3") as String;
        state.value = TransferImporting("Downloading ${index + 1}/${files.length}: $name");

        try {
          final response = await _http
              .get(Uri.parse("${peer.url}/file/$index"))
              .timeout(const Duration(minutes: 2));
          if (response.statusCode != 200) continue;

          final written = await importer.writeImported(name, response.bodyBytes);
          if (written != null) imported++;
        } catch (e) {
          _log.warning("Could not fetch '$name' from ${peer.name}: $e");
        }
      }

      if (imported > 0) await importer.rescan();

      state.value = TransferDone(imported);
      _log.info("Imported $imported file(s) from ${peer.name}");
    } catch (e) {
      _log.warning("Transfer from ${peer.name} failed: $e");
      state.value = TransferFailed("Couldn't reach ${peer.name}");
    }
  }
}
