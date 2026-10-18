import 'dart:convert';

import 'package:diapason/services/connect/connect_mdns.dart';
import 'package:diapason/services/tvos/appletv_audio_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:nsd/nsd.dart' as nsd;

/// A diapason-uploader sidecar found on the local network via mDNS.
///
/// The advertisement never contains a credential. When [canPair] is set the
/// sidecar accepts the pairing handshake (see [UploaderClient.pair]), which
/// gives this device a token of its own.
class DiscoveredUploader {
  const DiscoveredUploader({required this.name, required this.baseUrl, required this.canPair, required this.tls});

  final String name;
  final String baseUrl;
  final bool canPair;
  final bool tls;

  @override
  bool operator ==(Object other) => other is DiscoveredUploader && other.baseUrl == baseUrl;

  @override
  int get hashCode => baseUrl.hashCode;
}

/// Browses for diapason-uploader sidecars advertising `_diapason-uploader._tcp`
/// over mDNS, mirroring how [ConnectService] discovers other Diapason devices.
class UploaderDiscoveryService {
  static final _log = Logger("UploaderDiscoveryService");
  static const serviceType = "_diapason-uploader._tcp";

  nsd.Discovery? _discovery;

  TvOsMdns? _tvOs;

  final ValueNotifier<List<DiscoveredUploader>> devices = ValueNotifier(const []);

  bool get isDiscovering => _discovery != null || _tvOs != null;

  Future<void> start() async {
    if (isDiscovering) return;
    devices.value = const [];
    if (AppleTvAudioChannel.isSupported) {
      final mdns = TvOsMdns();
      _tvOs = mdns;
      try {
        await mdns.startBrowse(serviceType, (services) {
          devices.value = services.map(_fromMdns).nonNulls.toList();
        });
      } catch (e) {
        _tvOs = null;
        _log.warning("Could not browse for uploaders: $e");
      }
      return;
    }
    try {
      nsd.disableServiceTypeValidation(true);
      final discovery = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.v4);
      _discovery = discovery;
      discovery.addListener(() {
        devices.value = discovery.services.map(_toDevice).nonNulls.toList();
      });
    } catch (e) {
      _log.warning("Could not browse for uploaders: $e");
    }
  }

  Future<void> stop() async {
    final tvOs = _tvOs;
    if (tvOs != null) {
      _tvOs = null;
      try {
        await tvOs.stopBrowse();
      } catch (_) {}
      return;
    }
    if (_discovery == null) return;
    try {
      await nsd.stopDiscovery(_discovery!);
    } catch (_) {}
    _discovery = null;
  }

  DiscoveredUploader? _toDevice(nsd.Service service) {
    final txt = service.txt ?? const {};
    return _build(
      name: service.name,
      host: service.host,
      port: service.port,
      tls: _decode(txt["tls"]) == "1",
      pairing: _decode(txt["pair"]) == "1",
    );
  }

  DiscoveredUploader? _fromMdns(MdnsService service) => _build(
    name: service.name.isEmpty ? null : service.name,
    host: service.host == null || service.host!.isEmpty ? null : service.host,
    port: service.port,
    tls: service.txt["tls"] == "1",
    pairing: service.txt["pair"] == "1",
  );

  DiscoveredUploader? _build({
    required String? name,
    required String? host,
    required int? port,
    required bool tls,
    required bool pairing,
  }) {
    if (host == null || port == null) return null;

    final normalized = host.endsWith(".") ? host.substring(0, host.length - 1) : host;
    final scheme = tls ? "https" : "http";

    return DiscoveredUploader(
      name: name ?? "diapason-uploader",
      baseUrl: "$scheme://$normalized:$port",
      canPair: pairing,
      tls: tls,
    );
  }

  String? _decode(dynamic bytes) {
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes as List<int>);
    } catch (_) {
      return null;
    }
  }
}
