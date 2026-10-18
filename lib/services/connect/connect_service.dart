import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:diapason/services/connect/connect_mdns.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class ConnectService {
  ConnectService({http.Client? httpClient, ConnectMdns? mdns})
    : _http = httpClient ?? http.Client(),
      _mdns = mdns ?? defaultConnectMdns();

  static final _log = Logger("ConnectService");
  static const serviceType = "_diapason-connect._tcp";
  static const _pollInterval = Duration(seconds: 2);

  final http.Client _http;
  final ConnectMdns _mdns;

  HttpServer? _server;
  bool _discovering = false;
  Timer? _pollTimer;

  String _token = "";
  int _port = 0;

  final ValueNotifier<List<ConnectDevice>> devices = ValueNotifier(const []);

  final ValueNotifier<ConnectDevice?> connectedDevice = ValueNotifier(null);

  final ValueNotifier<ConnectStatus?> remoteStatus = ValueNotifier(null);

  ConnectStatus Function()? localStatusProvider;

  void Function(ConnectCommand command)? onCommand;

  /// Another device sent us a queue to play.
  void Function(ConnectQueue queue)? onPlayQueue;

  /// Our queue, for a controller to mirror.
  ConnectQueue Function()? queueProvider;

  /// Called when the device we control stopped answering and we let go of it.
  void Function(ConnectDevice device)? onConnectionLost;

  int _failedPolls = 0;
  static const _maxFailedPolls = 4;

  Future<List<Map<String, dynamic>>> Function()? libraryProvider;

  /// Whether this device takes accounts sent from another one. Only the TV does, and only while its landing screen
  /// is up, so a phone never gets credentials pushed at it.
  bool acceptSources = false;

  /// The latest accounts another device sent, waiting for the user to accept or refuse them.
  final ValueNotifier<SourceOffer?> sourceOffer = ValueNotifier(null);

  bool get isServing => _server != null;
  bool get isControlling => connectedDevice.value != null;

  String? get serverUrl => _port == 0 ? null : "http://${_localAddress ?? "127.0.0.1"}:$_port/$_token/connect";

  String? _localAddress;

  static String _randomToken() {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    final rng = Random.secure();
    return List.generate(24, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// The name we advertise ourselves as.
  String deviceName = "Diapason";

  Future<void> start({String deviceName = "Diapason"}) async {
    if (_server != null) return;
    this.deviceName = deviceName;

    _token = _randomToken();
    _localAddress = await _bestLocalAddress();

    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _port = server.port;
    unawaited(_serve(server));

    try {
      await _mdns.register(name: deviceName, type: serviceType, port: _port, txt: {"token": _token});
      _log.info("Connect is serving on port $_port and advertising as '$deviceName'");
    } catch (e) {
      _log.warning("Could not advertise over mDNS: $e");
    }
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await stopDiscovery();

    try {
      await _mdns.unregister();
    } catch (_) {}
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

      case ("GET", "queue"):
        final queue = queueProvider?.call() ?? const ConnectQueue(items: [], index: 0, position: 0);
        response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(queue.toJson()));

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
        final queue =
            ConnectQueue.tryParse(body) ??
            // Devices from before queue mirroring send {songs: [{id, ...}], startIndex}.
            ConnectQueue.tryParse({
              "items": [
                for (final song in (body?["songs"] as List<dynamic>? ?? const []).whereType<Map>()) {"Id": song["id"]},
              ],
              "index": body?["startIndex"] ?? 0,
            });
        if (queue != null && !queue.isEmpty) onPlayQueue?.call(queue);
        response.write("ok");

      case ("POST", "import-sources"):
        final body = await _readJson(request);
        final offer = acceptSources ? SourceOffer.tryParse(body, from: (body?["from"] as String?) ?? "") : null;
        if (offer == null) {
          response.statusCode = acceptSources ? HttpStatus.badRequest : HttpStatus.forbidden;
        } else {
          sourceOffer.value = offer;
          response.write("ok");
        }

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
    if (_discovering) return;
    devices.value = const [];

    try {
      _discovering = true;
      await _mdns.startBrowse(serviceType, (services) {
        devices.value = services.map(_toDevice).nonNulls.where(_isNotUs).toList();
      });
    } catch (e) {
      _discovering = false;
      _log.warning("Could not browse for Connect devices: $e");
    }
  }

  Future<void> stopDiscovery() async {
    if (!_discovering) return;
    _discovering = false;
    try {
      await _mdns.stopBrowse();
    } catch (_) {}
  }

  ConnectDevice? _toDevice(MdnsService service) {
    final host = service.host;
    final port = service.port;
    final token = service.txt["token"];
    if (host == null || port == null || token == null || token.isEmpty) return null;

    final normalized = host.endsWith(".") ? host.substring(0, host.length - 1) : host;
    return ConnectDevice(
      name: service.name.isEmpty ? "Diapason" : service.name,
      baseUrl: "http://$normalized:$port/$token/connect",
    );
  }

  bool _isNotUs(ConnectDevice device) => !device.baseUrl.contains("/$_token/");

  /// Starts controlling [device]. False when it does not answer.
  Future<bool> connect(ConnectDevice device) async {
    final status = await fetchStatus(device);
    if (status == null) return false;

    _failedPolls = 0;
    remoteStatus.value = status;
    connectedDevice.value = device;
    await _register(device);

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollStatus());
    return true;
  }

  Future<ConnectStatus?> fetchStatus(ConnectDevice device) async {
    try {
      final response = await _http.get(device.endpoint("status")).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;
      return ConnectStatus.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      _log.fine("Could not reach ${device.name}: $e");
      return null;
    }
  }

  /// The controlled device's whole queue; null when unreachable or too old to share it.
  Future<ConnectQueue?> fetchQueue() async {
    final device = connectedDevice.value;
    if (device == null) return null;
    try {
      final response = await _http.get(device.endpoint("queue")).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return ConnectQueue.tryParse(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      _log.fine("Could not fetch the queue of ${device.name}: $e");
      return null;
    }
  }

  /// Polls right away instead of waiting for the next tick, e.g. after a command.
  Future<void> refresh() => _pollStatus();

  void disconnect() {
    _pollTimer?.cancel();
    _pollTimer = null;
    connectedDevice.value = null;
    remoteStatus.value = null;
  }

  Future<void> _register(ConnectDevice device) async {
    final url = serverUrl;
    if (url == null) return;
    await _post(device.endpoint("register"), {"name": deviceName, "url": url});
  }

  Future<void> _pollStatus() async {
    final device = connectedDevice.value;
    if (device == null) return;

    final status = await fetchStatus(device);
    if (connectedDevice.value != device) return;
    if (status != null) {
      _failedPolls = 0;
      remoteStatus.value = status;
      return;
    }
    if (++_failedPolls >= _maxFailedPolls) {
      _log.warning("${device.name} stopped answering; disconnecting");
      disconnect();
      onConnectionLost?.call(device);
    }
  }

  Future<void> sendCommand(
    String action, {
    double? position,
    double? volume,
    Map<String, dynamic> args = const {},
  }) async {
    final device = connectedDevice.value;
    if (device == null) return;

    await _post(
      device.endpoint("command"),
      ConnectCommand(action, position: position, volume: volume, args: args).toJson(),
    );
    await _pollStatus();
  }

  /// Replaces the controlled device's queue and starts it.
  Future<void> playQueue(ConnectQueue queue) async {
    final device = connectedDevice.value;
    if (device == null) return;

    await _post(device.endpoint("play-queue"), queue.toJson(), timeout: const Duration(seconds: 10));
    await _pollStatus();
  }

  /// Offers [sources] to [device], to land in its profile [profileName]. True when the device took the offer to ask
  /// its user; false when it does not accept accounts or could not be reached.
  Future<bool> sendSources(
    ConnectDevice device,
    List<Map<String, dynamic>> sources, {
    String profileName = "Home",
    String from = "Diapason",
  }) async {
    try {
      final response = await _http
          .post(
            device.endpoint("import-sources"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode(SourceOffer(profileName: profileName, sources: sources, from: from).toJson()),
          )
          .timeout(const Duration(seconds: 6));
      return response.statusCode == 200;
    } catch (e) {
      _log.fine("Could not send accounts to ${device.name}: $e");
      return false;
    }
  }

  Future<void> _post(Uri url, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 4)}) async {
    try {
      await _http.post(url, headers: {"Content-Type": "application/json"}, body: jsonEncode(body)).timeout(timeout);
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
