import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:nsd/nsd.dart' as nsd;

/// An HTTP client that copes with `.local` names the app's resolver can't look up.
///
/// The system resolver inside the app sometimes fails on mDNS names (macOS and iOS local network privacy, flaky
/// multicast, hosts that only publish some address families) even while Bonjour browsing works — Diapason Connect
/// finds devices fine. When a `.local` lookup fails, the host is resolved through Bonjour instead (by browsing for
/// [serviceType]), and that address is used for this and later requests to the host.
class LocalNameFallbackClient extends http.BaseClient {
  LocalNameFallbackClient(
    this._inner, {
    required this.serviceType,
    Future<InternetAddress?> Function(String host)? resolve,
  }) : _resolve = resolve;

  static final _log = Logger("LocalNameFallback");

  final http.Client _inner;
  final String serviceType;
  final Future<InternetAddress?> Function(String host)? _resolve;

  /// `.local` host → the address Bonjour gave for it. Shared, so URLs handed to players and images can use it too.
  static final resolved = <String, InternetAddress>{};

  /// Hosts Bonjour couldn't find either, and when: not asked again for a minute.
  static final _unresolvable = <String, DateTime>{};

  static bool isLookupFailure(Object error) {
    final text = "$error";
    return text.contains("Failed host lookup") || text.contains("nodename nor servname");
  }

  /// [uri] with a `.local` host replaced by the address Bonjour found for it, if one is known (plain http only:
  /// certificates are for names, not addresses).
  static Uri rewrite(Uri uri) {
    final address = resolved[uri.host.toLowerCase()];
    if (address == null || uri.scheme != "http") return uri;
    return uri.replace(host: address.address);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host.toLowerCase();
    if (resolved.containsKey(host)) return _inner.send(_retarget(request) ?? request);
    try {
      return await _inner.send(request);
    } catch (e) {
      if (!host.endsWith(".local") || request.url.scheme != "http" || !isLookupFailure(e)) rethrow;
      final failedAt = _unresolvable[host];
      if (failedAt != null && DateTime.now().difference(failedAt) < const Duration(minutes: 1)) rethrow;
      final address = await (_resolve ?? _resolveWithBonjour)(host);
      if (address == null) {
        _unresolvable[host] = DateTime.now();
        rethrow;
      }
      _unresolvable.remove(host);
      resolved[host] = address;
      _log.info("'$host' doesn't resolve here; using ${address.address}, found through Bonjour");
      final retry = _retarget(request);
      if (retry == null) rethrow; // a streamed body can't be sent twice; the next request will use the address
      return _inner.send(retry);
    }
  }

  /// A copy of [request] sent to the resolved address. Null when the body can't be replayed.
  http.BaseRequest? _retarget(http.BaseRequest request) {
    final url = rewrite(request.url);
    final headers = {
      ...request.headers,
      "Host": request.url.hasPort ? "${request.url.host}:${request.url.port}" : request.url.host,
    };
    final http.BaseRequest copy;
    if (request is http.Request) {
      copy = http.Request(request.method, url)..bodyBytes = request.bodyBytes;
    } else if (request is http.MultipartRequest && !request.finalized) {
      copy = http.MultipartRequest(request.method, url)
        ..fields.addAll(request.fields)
        ..files.addAll(request.files);
    } else {
      return null;
    }
    copy.headers.addAll(headers);
    copy
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection;
    return copy;
  }

  Future<InternetAddress?> _resolveWithBonjour(String host) async {
    nsd.Discovery? discovery;
    final found = Completer<InternetAddress?>();
    try {
      nsd.disableServiceTypeValidation(true);
      discovery = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.any);
      void check() {
        for (final service in discovery!.services) {
          final name = (service.host ?? "").toLowerCase().replaceFirst(RegExp(r"\.$"), "");
          if (name != host) continue;
          final addresses = service.addresses ?? const <InternetAddress>[];
          final best =
              addresses.where((a) => a.type == InternetAddressType.IPv4).firstOrNull ??
              addresses.where((a) => !a.isLinkLocal).firstOrNull;
          if (best != null && !found.isCompleted) found.complete(best);
        }
      }

      discovery.addListener(check);
      check();
      return await found.future.timeout(const Duration(seconds: 5), onTimeout: () => null);
    } catch (e) {
      _log.fine("Bonjour couldn't resolve '$host': $e");
      return null;
    } finally {
      if (discovery != null) {
        try {
          await nsd.stopDiscovery(discovery);
        } catch (_) {}
      }
    }
  }
}
