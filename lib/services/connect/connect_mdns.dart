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

  static final Map<String, void Function(List<MdnsService> services)> _browsers = {};
  static bool _handlerSet = false;

  static String _key(String type) => type.endsWith(".") ? type.substring(0, type.length - 1) : type;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == "services") {
        final args = call.arguments as Map<Object?, Object?>;
        final list = (args["services"] as List).cast<Map<Object?, Object?>>();
        _browsers[_key(args["type"] as String)]?.call(list.map(MdnsService.fromMap).toList());
      } else if (call.method == "log") {
        _log.info(call.arguments);
      }
    });
  }

  TvOsMdns() {
    _ensureHandler();
  }

  String? _browsing;

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
    _browsing = _key(type);
    _browsers[_key(type)] = onChanged;
    await _channel.invokeMethod("startBrowse", {"type": type});
  }

  @override
  Future<void> stopBrowse() async {
    final type = _browsing;
    _browsing = null;
    if (type == null) return;
    _browsers.remove(type);
    await _channel.invokeMethod("stopBrowse", {"type": type});
  }
}
