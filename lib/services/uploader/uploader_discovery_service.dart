import 'dart:convert';

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

  final ValueNotifier<List<DiscoveredUploader>> devices = ValueNotifier(const []);

  bool get isDiscovering => _discovery != null;

  Future<void> start() async {
    if (_discovery != null) return;
    devices.value = const [];
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
    if (_discovery == null) return;
    try {
      await nsd.stopDiscovery(_discovery!);
    } catch (_) {}
    _discovery = null;
  }

  DiscoveredUploader? _toDevice(nsd.Service service) {
    final host = service.host;
    final port = service.port;
    if (host == null || port == null) return null;

    final txt = service.txt ?? const {};
    final tls = _decode(txt["tls"]) == "1";
    final pairing = _decode(txt["pair"]) == "1";

    final normalized = host.endsWith(".") ? host.substring(0, host.length - 1) : host;
    final scheme = tls ? "https" : "http";

    return DiscoveredUploader(
      name: service.name ?? "diapason-uploader",
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
