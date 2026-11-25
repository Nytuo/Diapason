import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:diapason/services/dlna/dlna_client.dart';
import 'package:diapason/services/dlna/dlna_protocol.dart';
import 'package:logging/logging.dart';

/// Finds DLNA media servers on the LAN with an SSDP M-SEARCH.
///
/// On iOS, sending to the multicast group needs the
/// `com.apple.developer.networking.multicast` entitlement, which Apple grants
/// on request. Without it the send fails, discovery returns nothing, and the
/// user enters the server's address by hand.
class SsdpDiscovery {
  SsdpDiscovery({DlnaClient? client}) : _client = client ?? DlnaClient();

  static final _log = Logger("SsdpDiscovery");

  final DlnaClient _client;

  static const _targets = [dlnaMediaServerDeviceType, dlnaContentDirectoryService];

  /// Description locations that answered within [timeout].
  Future<Set<Uri>> searchLocations({Duration timeout = const Duration(seconds: 3)}) async {
    final locations = <Uri>{};
    final sockets = <RawDatagramSocket>[];
    final group = InternetAddress(ssdpAddress);

    final bindAddresses = <InternetAddress>[];
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      bindAddresses.addAll(interfaces.expand((i) => i.addresses));
    } catch (e) {
      _log.fine("Couldn't list network interfaces: $e");
    }
    if (bindAddresses.isEmpty) bindAddresses.add(InternetAddress.anyIPv4);

    for (final address in bindAddresses) {
      try {
        final socket = await RawDatagramSocket.bind(address, 0);
        socket.multicastHops = 4;
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          final location = parseSsdpLocation(utf8.decode(datagram.data, allowMalformed: true));
          if (location != null) locations.add(location);
        }, onError: (Object e) => _log.fine("SSDP socket on ${address.address} failed: $e"));
        sockets.add(socket);
      } catch (e) {
        _log.fine("Couldn't bind an SSDP socket on ${address.address}: $e");
      }
    }

    void send() {
      for (final socket in sockets) {
        for (final target in _targets) {
          try {
            socket.send(utf8.encode(buildMSearch(searchTarget: target)), group, ssdpPort);
          } catch (e) {
            // iOS without the multicast entitlement, or an interface without multicast.
            _log.fine("SSDP send failed: $e");
          }
        }
      }
    }

    send();
    final resend = Timer(const Duration(milliseconds: 700), send);
    await Future<void>.delayed(timeout);
    resend.cancel();
    for (final socket in sockets) {
      socket.close();
    }
    return locations;
  }

  /// Media servers that answered, read from their descriptions, one per UDN.
  Future<List<DlnaDevice>> discover({Duration timeout = const Duration(seconds: 3)}) async {
    final locations = await searchLocations(timeout: timeout);
    final devices = await Future.wait(
      locations.map((location) async {
        try {
          return await _client.describe(location, timeout: const Duration(seconds: 4));
        } catch (e) {
          _log.fine("Ignoring $location: $e");
          return null;
        }
      }),
    );
    final byUdn = <String, DlnaDevice>{};
    for (final device in devices.nonNulls) {
      byUdn.putIfAbsent(device.udn.isEmpty ? device.location.toString() : device.udn, () => device);
    }
    final list = byUdn.values.toList()..sort((a, b) => a.friendlyName.compareTo(b.friendlyName));
    _log.info("SSDP found ${list.length} media server(s).");
    return list;
  }
}
