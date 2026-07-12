import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:diapason/services/connect/connect_models.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:nsd/nsd.dart' as nsd;

class ConnectService {
  ConnectService({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("ConnectService");
  static const serviceType = "_diapason-connect._tcp";
  static const _pollInterval = Duration(seconds: 2);

  static void _allowLongServiceName() => nsd.disableServiceTypeValidation(true);

  final http.Client _http;

  HttpServer? _server;
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  Timer? _pollTimer;

  String _token = "";
  int _port = 0;

  final ValueNotifier<List<ConnectDevice>> devices = ValueNotifier(const []);

  final ValueNotifier<ConnectDevice?> connectedDevice = ValueNotifier(null);

  final ValueNotifier<ConnectStatus?> remoteStatus = ValueNotifier(null);

  ConnectStatus Function()? localStatusProvider;

  void Function(ConnectCommand command)? onCommand;

  void Function(List<Map<String, dynamic>> songs, int startIndex)? onPlayQueue;

  Future<List<Map<String, dynamic>>> Function()? libraryProvider;

  bool get isServing => _server != null;
  bool get isControlling => connectedDevice.value != null;

  String? get serverUrl => _port == 0 ? null : "http://${_localAddress ?? "127.0.0.1"}:$_port/$_token/connect";

  String? _localAddress;

  static String _randomToken() {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    final rng = Random.secure();
    return List.generate(24, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Future<void> start({String deviceName = "Diapason"}) async {
    if (_server != null) return;

    _token = _randomToken();
    _localAddress = await _bestLocalAddress();

    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _port = server.port;
    unawaited(_serve(server));

    try {
      _allowLongServiceName();
      _registration = await nsd.register(
        nsd.Service(
          name: deviceName,
          type: serviceType,
          port: _port,
          txt: {"token": Uint8List.fromList(utf8.encode(_token))},
        ),
      );
      _log.info("Connect is serving on port $_port and advertising as '$deviceName'");
    } catch (e) {
      _log.warning("Could not advertise over mDNS: $e");
    }
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await stopDiscovery();

    if (_registration != null) {
      try {
        await nsd.unregister(_registration!);
      } catch (_) {}
      _registration = null;
    }
    await _server?.close(force: true);
    _server = null;
    _port = 0;
    connectedDevice.value = null;
    remoteStatus.value = null;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _handle(request);
      } catch (e) {
        _log.warning("Connect request failed: $e");
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set("Access-Control-Allow-Origin", "*");

    if (request.method == "OPTIONS") {
      response
        ..statusCode = HttpStatus.noContent
        ..headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        ..headers.set("Access-Control-Allow-Headers", "Content-Type");
      await response.close();
      return;
    }

    final prefix = "/$_token/connect/";
    if (!request.uri.path.startsWith(prefix)) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final endpoint = request.uri.path.substring(prefix.length);

    switch ((request.method, endpoint)) {
      case ("GET", "status"):
        final status = localStatusProvider?.call() ?? ConnectStatus.stopped;
        response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(status.toJson()));

      case ("GET", "library"):
        final tracks = await libraryProvider?.call() ?? const <Map<String, dynamic>>[];
        response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({"tracks": tracks}));

      case ("POST", "command"):
        final body = await _readJson(request);
        if (body != null) onCommand?.call(ConnectCommand.fromJson(body));
        response.write("ok");

      case ("POST", "play-queue"):
        final body = await _readJson(request);
        final songs = (body?["songs"] as List<dynamic>?)?.cast<Map<String, dynamic>>();
        if (songs != null) {
          onPlayQueue?.call(songs, (body?["startIndex"] as num?)?.toInt() ?? 0);
        }
        response.write("ok");

      case ("POST", "register"):
        final body = await _readJson(request);
        final name = body?["name"] as String?;
        final url = body?["url"] as String?;
        if (name != null && url != null && url.isNotEmpty) {
          final device = ConnectDevice(name: name, baseUrl: url);
          if (!devices.value.contains(device)) {
            devices.value = [...devices.value, device];
          }
          _log.info("Device registered with us: $device");
        }
        response.write("ok");

      default:
        response.statusCode = HttpStatus.notFound;
    }

    await response.close();
  }

  Future<Map<String, dynamic>?> _readJson(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      if (body.isEmpty) return null;
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      _log.fine("Malformed Connect body: $e");
      return null;
    }
  }

  Future<void> startDiscovery() async {
    if (_discovery != null) return;
    devices.value = const [];

    try {
      _allowLongServiceName();
      final discovery = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.v4);
      _discovery = discovery;
      discovery.addListener(() {
        devices.value = discovery.services.map(_toDevice).nonNulls.where(_isNotUs).toList();
      });
    } catch (e) {
      _log.warning("Could not browse for Connect devices: $e");
    }
  }

  Future<void> stopDiscovery() async {
    if (_discovery == null) return;
    try {
      await nsd.stopDiscovery(_discovery!);
    } catch (_) {}
    _discovery = null;
  }

  ConnectDevice? _toDevice(nsd.Service service) {
    final host = service.host;
    final port = service.port;
    final tokenBytes = service.txt?["token"];
    if (host == null || port == null || tokenBytes == null) return null;

    final token = utf8.decode(tokenBytes);
    if (token.isEmpty) return null;

    final normalized = host.endsWith(".") ? host.substring(0, host.length - 1) : host;
    return ConnectDevice(name: service.name ?? "Diapason", baseUrl: "http://$normalized:$port/$token/connect");
  }

  bool _isNotUs(ConnectDevice device) => !device.baseUrl.contains("/$_token/");

  Future<void> connect(ConnectDevice device) async {
    connectedDevice.value = device;
    await _register(device);

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollStatus());
    await _pollStatus();
  }

  void disconnect() {
    _pollTimer?.cancel();
    _pollTimer = null;
    connectedDevice.value = null;
    remoteStatus.value = null;
  }

  Future<void> _register(ConnectDevice device) async {
    final url = serverUrl;
    if (url == null) return;
    await _post(device.endpoint("register"), {"name": "Diapason", "url": url});
  }

  Future<void> _pollStatus() async {
    final device = connectedDevice.value;
    if (device == null) return;

    try {
      final response = await _http.get(device.endpoint("status")).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return;
      remoteStatus.value = ConnectStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e) {
      _log.fine("Could not reach ${device.name}: $e");
    }
  }

  Future<void> sendCommand(String action, {double? position, double? volume}) async {
    final device = connectedDevice.value;
    if (device == null) return;

    await _post(device.endpoint("command"), ConnectCommand(action, position: position, volume: volume).toJson());
    await _pollStatus();
  }

  Future<void> castQueue(List<ConnectSong> songs, {int startIndex = 0}) async {
    final device = connectedDevice.value;
    if (device == null) return;

    await _post(device.endpoint("play-queue"), {
      "songs": songs.map((s) => s.toJson()).toList(),
      "startIndex": startIndex,
    });
  }

  Future<void> _post(Uri url, Map<String, dynamic> body) async {
    try {
      await _http
          .post(url, headers: {"Content-Type": "application/json"}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 4));
    } catch (e) {
      _log.fine("Connect POST to $url failed: $e");
    }
  }

  static Future<String?> _bestLocalAddress() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (e) {
      _log.fine("Could not determine a local address: $e");
    }
    return null;
  }
}
