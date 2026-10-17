import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:diapason/services/tvos/appletv_audio_channel.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:nsd/nsd.dart' as nsd;

class MdnsService {
  const MdnsService({required this.name, required this.host, required this.port, this.txt = const {}});

  final String name;
  final String? host;
  final int? port;
  final Map<String, String> txt;

  factory MdnsService.fromMap(Map<Object?, Object?> map) => MdnsService(
    name: (map["name"] as String?) ?? "",
    host: map["host"] as String?,
    port: (map["port"] as num?)?.toInt(),
    txt: ((map["txt"] as Map?) ?? const {}).map((k, v) => MapEntry("$k", "$v")),
  );
}

abstract interface class ConnectMdns {
  Future<void> register({
    required String name,
    required String type,
    required int port,
    required Map<String, String> txt,
  });

  Future<void> unregister();

  Future<void> startBrowse(String type, void Function(List<MdnsService> services) onChanged);

  Future<void> stopBrowse();
}

ConnectMdns defaultConnectMdns() => AppleTvAudioChannel.isSupported ? TvOsMdns() : NsdMdns();

class NsdMdns implements ConnectMdns {
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;

  static void _allowLongServiceName() => nsd.disableServiceTypeValidation(true);

  @override
  Future<void> register({
    required String name,
    required String type,
    required int port,
    required Map<String, String> txt,
  }) async {
    _allowLongServiceName();
    _registration = await nsd.register(
      nsd.Service(
        name: name,
        type: type,
        port: port,
        txt: {for (final e in txt.entries) e.key: Uint8List.fromList(utf8.encode(e.value))},
      ),
    );
  }

  @override
  Future<void> unregister() async {
    final registration = _registration;
    _registration = null;
    if (registration == null) return;
    try {
      await nsd.unregister(registration);
    } catch (_) {}
  }

  @override
  Future<void> startBrowse(String type, void Function(List<MdnsService> services) onChanged) async {
    if (_discovery != null) return;
    _allowLongServiceName();
    final discovery = await nsd.startDiscovery(type, ipLookupType: nsd.IpLookupType.v4);
    _discovery = discovery;
    discovery.addListener(() {
      onChanged([
        for (final s in discovery.services)
          MdnsService(
            name: s.name ?? "",
            host: s.host,
            port: s.port,
            txt: {
              for (final e in (s.txt ?? const <String, Uint8List?>{}).entries)
                if (e.value != null) e.key: utf8.decode(e.value!, allowMalformed: true),
            },
          ),
      ]);
    });
  }

  @override
  Future<void> stopBrowse() async {
    final discovery = _discovery;
    _discovery = null;
    if (discovery == null) return;
    try {
      await nsd.stopDiscovery(discovery);
    } catch (_) {}
  }
}

class TvOsMdns implements ConnectMdns {
  static final _log = Logger("TvOsMdns");
  static const _channel = MethodChannel("fr.nytuo.diapason/appletv_bonjour");

  void Function(List<MdnsService> services)? _onChanged;

  TvOsMdns() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == "services") {
        final list = (call.arguments as List).cast<Map<Object?, Object?>>();
        _onChanged?.call(list.map(MdnsService.fromMap).toList());
      }
    });
  }

  @override
  Future<void> register({
    required String name,
    required String type,
    required int port,
    required Map<String, String> txt,
  }) async {
    await _channel.invokeMethod("register", {"name": name, "type": type, "port": port, "txt": txt});
    _log.info("Advertising '$name' ($type) on port $port");
  }

  @override
  Future<void> unregister() => _channel.invokeMethod("unregister");

  @override
  Future<void> startBrowse(String type, void Function(List<MdnsService> services) onChanged) async {
    _onChanged = onChanged;
    await _channel.invokeMethod("startBrowse", {"type": type});
  }

  @override
  Future<void> stopBrowse() async {
    _onChanged = null;
    await _channel.invokeMethod("stopBrowse");
  }
}
