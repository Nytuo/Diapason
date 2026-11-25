import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:diapason/services/no_network_guard.dart';
import 'package:diapason/services/connect/connect_mdns.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// What we advertise ourselves as (see [ConnectDevice.role]).
  String role = ConnectDevice.rolePlayer;

  bool _advertised = false;

  /// This install's stable id and when this listener started, announced so others can tell restarts from new devices.
  String? _instanceId;
  int _startedAt = 0;

  Future<String> _loadInstanceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString("connect_instance_id");
      if (id == null || id.isEmpty) {
        id = _randomToken();
        await prefs.setString("connect_instance_id", id);
      }
      return id;
    } catch (_) {
      return _randomToken();
    }
  }

  /// What the last [start] asked for, kept so the listener can be brought back after the OS took it away.
  bool _wantServing = false;
  bool _wantAdvertise = true;
  Timer? _watchdog;
  _ConnectLifecycle? _lifecycle;

  /// Answers browse requests from a controller (protocol 2). Unset: `GET browse` answers 404, as on older devices.
  Future<List<ConnectBrowseItem>> Function(ConnectBrowseRequest request)? browseProvider;

  /// Serves artwork to a controller (protocol 2).
  Future<({List<int> bytes, String contentType})?> Function(String id, int size)? artProvider;

  /// Starts answering other devices. With [advertise] false nobody finds us until [setAdvertised] says so: a watch
  /// only shows up while it waits for accounts, so phones never offer it as a speaker.
  Future<void> start({
    String deviceName = "Diapason",
    String role = ConnectDevice.rolePlayer,
    bool advertise = true,
  }) async {
    if (_server != null) return;
    this.deviceName = deviceName;
    this.role = role;
    _wantAdvertise = advertise;
    _wantServing = true;
    if (NoNetworkGuard.active) {
      _log.info("Not starting Connect: no network mode is on");
      return;
    }

    _token = _randomToken();
    _instanceId ??= await _loadInstanceId();
    _startedAt = DateTime.now().millisecondsSinceEpoch;
    _localAddress = await _bestLocalAddress();

    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _port = server.port;
    unawaited(_serve(server));
    _log.info("Connect is serving on port $_port");

    if (advertise) await setAdvertised(true);
  }

  /// Starts or stops advertising over mDNS, while the server keeps running.
  Future<void> setAdvertised(bool advertised) async {
    if (_server == null || advertised == _advertised) return;
    _advertised = advertised;
    try {
      if (advertised) {
        await _mdns.register(
          name: deviceName,
          type: serviceType,
          port: _port,
          txt: {
            "token": _token,
            "id": ?_instanceId,
            "t": "$_startedAt",
            if (role != ConnectDevice.rolePlayer) "role": role,
          },
        );
        _log.info("Advertising as '$deviceName' ($role)");
      } else {
        await _mdns.unregister();
      }
    } catch (e) {
      _log.warning("Could not ${advertised ? "advertise" : "stop advertising"} over mDNS: $e");
    }
  }

  /// Whether the listener really accepts connections now. A suspended app (an Apple TV coming out of idle, a phone
  /// in the background) can have its sockets closed while [_server] still looks alive, and its mDNS record can go
  /// stale: other devices then see us in their list but cannot connect.
  Future<bool> _listenerAlive() async {
    if (_server == null || _port == 0) return false;
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, _port, timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Makes sure we can be reached: restarts the listener when it died (or never started), and re-announces on mDNS
  /// when [reannounce] is set (after the app came back to the front).
  Future<void> ensureServing({bool reannounce = false}) async {
    if (!_wantServing) return;
    if (_ensuring) return;
    _ensuring = true;
    try {
      if (!await _listenerAlive()) {
        _log.info("Connect listener is gone; restarting it");
        final name = deviceName;
        final currentRole = role;
        final advertise = _wantAdvertise;
        // Only the listener is rebuilt: a controller's discovery and the device it is controlling stay as they are.
        try {
          await _mdns.unregister();
        } catch (_) {}
        _advertised = false;
        try {
          await _server?.close(force: true);
        } catch (_) {}
        _server = null;
        _port = 0;
        await start(deviceName: name, role: currentRole, advertise: advertise);
      } else if (reannounce && _advertised) {
        _localAddress = await _bestLocalAddress();
        _advertised = false;
        try {
          await _mdns.unregister();
        } catch (_) {}
        await setAdvertised(true);
      }
    } catch (e) {
      _log.warning("Could not make sure Connect is reachable: $e");
    } finally {
      _ensuring = false;
    }
  }

  bool _ensuring = false;

  /// Keeps us reachable for good: checks again whenever the app comes back to the front and every half minute.
  /// Meant for devices that are mostly waiting to be controlled, like a TV.
  void keepReachable() {
    _lifecycle ??= _ConnectLifecycle(() => unawaited(ensureServing(reannounce: true)))..attach();
    _watchdog ??= Timer.periodic(const Duration(seconds: 30), (_) => unawaited(ensureServing()));
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await stopDiscovery();

    try {
      await _mdns.unregister();
    } catch (_) {}
    _advertised = false;
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

      case ("GET", "browse"):
        final provider = browseProvider;
        final browse = ConnectBrowseRequest.tryParse(request.uri.queryParameters);
        if (provider == null) {
          response.statusCode = HttpStatus.notFound;
        } else if (browse == null) {
          response.statusCode = HttpStatus.badRequest;
        } else {
          final items = await provider(browse);
          response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({"items": items.map((i) => i.toJson()).toList()}));
        }

      case ("GET", "art"):
        final provider = artProvider;
        final id = request.uri.queryParameters["id"];
        final size = int.tryParse(request.uri.queryParameters["size"] ?? "") ?? 200;
        final art = provider == null || id == null || id.isEmpty ? null : await provider(id, size);
        if (art == null) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response
            ..headers.set(HttpHeaders.contentTypeHeader, art.contentType)
            ..headers.set(HttpHeaders.cacheControlHeader, "max-age=3600")
            ..add(art.bytes);
        }

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
                for (final song in (body?["songs"] as List<dynamic>? ?? const []).whereType<Map<dynamic, dynamic>>())
                  {"Id": song["id"]},
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
          final device = ConnectDevice(
            name: name,
            baseUrl: url,
            id: body?["id"] as String?,
            startedAt: (body?["t"] as num?)?.toInt(),
          );
          // One entry per device: registering again (after a restart, or on top of its mDNS record) replaces it.
          if (device.id != _instanceId) devices.value = ConnectDevice.unique([...devices.value, device]);
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
    if (_discovering || NoNetworkGuard.active) return;
    devices.value = const [];

    try {
      _discovering = true;
      await _mdns.startBrowse(serviceType, (services) {
        devices.value = ConnectDevice.unique(services.map(_toDevice).nonNulls.where(_isNotUs));
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
    final role = service.txt["role"];
    return ConnectDevice(
      name: service.name.isEmpty ? "Diapason" : service.name,
      baseUrl: "http://$normalized:$port/$token/connect",
      role: role == null || role.isEmpty ? ConnectDevice.rolePlayer : role,
      id: service.txt["id"],
      startedAt: int.tryParse(service.txt["t"] ?? ""),
    );
  }

  /// A device's library listing (protocol 2). Null when it cannot be reached or cannot be browsed.
  Future<List<ConnectBrowseItem>?> browse(ConnectBrowseRequest request, {ConnectDevice? device}) async {
    final target = device ?? connectedDevice.value;
    if (target == null) return null;
    try {
      final response = await _http
          .get(target.endpoint("browse", request.toQuery()))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      return ConnectBrowseItem.listFrom(jsonDecode(utf8.decode(response.bodyBytes)));
    } catch (e) {
      _log.fine("Could not browse ${target.name}: $e");
      return null;
    }
  }

  /// Where [device] (by default the controlled one) serves the artwork of item [id] (protocol 2).
  Uri? artUrl(String id, {int size = 200, ConnectDevice? device}) =>
      (device ?? connectedDevice.value)?.endpoint("art", {"id": id, "size": "$size"});

  bool _isNotUs(ConnectDevice device) =>
      !device.baseUrl.contains("/$_token/") && (device.id == null || device.id != _instanceId);

  /// Starts controlling [device]. False when it does not answer.
  Future<bool> connect(ConnectDevice device) async {
    var status = await fetchStatus(device);
    if (status == null) {
      // The device may have restarted its listener (new port and token) since it was listed: look again once.
      final fresh = await _rediscover(device);
      if (fresh != null) {
        device = fresh;
        status = await fetchStatus(device);
      }
    }
    if (status == null) return false;

    _failedPolls = 0;
    remoteStatus.value = status;
    connectedDevice.value = device;
    // A watch is a remote only: registering would make it show up as a speaker on the device it controls.
    if (role != ConnectDevice.roleWatch) await _register(device);

    _pollTimer?.cancel();
    // On a slow network a status request can outlast the poll interval; don't stack requests on top of each other.
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      if (!_polling) unawaited(_pollStatus());
    });
    return true;
  }

  /// Browses again for a device with [old]'s name and returns it when it now lives at another address.
  Future<ConnectDevice?> _rediscover(ConnectDevice old) async {
    try {
      await stopDiscovery();
      await startDiscovery();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final match = devices.value.where((d) => d.identity == old.identity && d.baseUrl != old.baseUrl).firstOrNull;
        if (match != null) return match;
      }
    } catch (e) {
      _log.fine("Could not look for ${old.name} again: $e");
    }
    return null;
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
    await _post(device.endpoint("register"), {"name": deviceName, "url": url, "id": _instanceId, "t": _startedAt});
  }

  bool _polling = false;

  Future<void> _pollStatus() async {
    final device = connectedDevice.value;
    if (device == null) return;
    _polling = true;
    final ConnectStatus? status;
    try {
      status = await fetchStatus(device);
    } finally {
      _polling = false;
    }
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

  /// Sends a command to the controlled device. False when it did not get there.
  Future<bool> sendCommand(
    String action, {
    double? position,
    double? volume,
    Map<String, dynamic> args = const {},
  }) async {
    final device = connectedDevice.value;
    if (device == null) return false;

    final ok = await _post(
      device.endpoint("command"),
      ConnectCommand(action, position: position, volume: volume, args: args).toJson(),
    );
    await _pollStatus();
    return ok;
  }

  /// Replaces the controlled device's queue and starts it. False when it did not get there.
  Future<bool> playQueue(ConnectQueue queue) async {
    final device = connectedDevice.value;
    if (device == null) return false;

    final ok = await _post(device.endpoint("play-queue"), queue.toJson(), timeout: const Duration(seconds: 10));
    await _pollStatus();
    return ok;
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

  Future<bool> _post(Uri url, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 4)}) async {
    try {
      final response = await _http
          .post(url, headers: {"Content-Type": "application/json"}, body: jsonEncode(body))
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (e) {
      _log.fine("Connect POST to $url failed: $e");
      return false;
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

/// Calls back when the app returns to the front.
class _ConnectLifecycle with WidgetsBindingObserver {
  _ConnectLifecycle(this.onResumed);

  final void Function() onResumed;

  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }
}
