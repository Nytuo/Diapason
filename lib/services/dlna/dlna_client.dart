import 'dart:async';
import 'dart:convert';

import 'package:diapason/services/dlna/dlna_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// HTTP side of a DLNA media server: its description and ContentDirectory.
class DlnaClient {
  DlnaClient({http.Client? client}) : _http = client ?? http.Client();

  static final _log = Logger("DlnaClient");

  final http.Client _http;

  static const _timeout = Duration(seconds: 15);

  /// Where a description usually is when only a host and port were typed:
  /// MiniDLNA/ReadyMedia, Gerbera, Serviio, UMS, Jellyfin's DLNA plugin.
  static const descriptionPaths = [
    "/rootDesc.xml",
    "/description.xml",
    "/DeviceDescription.xml",
    "/dms/description.xml",
    "/dlna/description.xml",
  ];

  Future<DlnaDevice> describe(Uri location, {Duration timeout = const Duration(seconds: 5)}) async {
    final response = await _http.get(location).timeout(timeout);
    if (response.statusCode != 200) {
      throw DlnaException("HTTP ${response.statusCode} for $location");
    }
    return parseDeviceDescription(utf8.decode(response.bodyBytes, allowMalformed: true), location);
  }

  /// Finds the media server at [address]: a description URL, or a host
  /// (and port), where the usual description paths are tried.
  Future<DlnaDevice> probe(String address) async {
    var text = address.trim();
    if (!text.contains("://")) text = "http://$text";
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) throw DlnaException("Invalid address: $address");
    if (uri.path.length > 1) return describe(uri);

    Object? lastError;
    for (final path in descriptionPaths) {
      try {
        return await describe(uri.replace(path: path));
      } catch (e) {
        lastError = e;
        _log.fine("No description at ${uri.replace(path: path)}: $e");
      }
    }
    throw lastError ?? DlnaException("No media server description at $address");
  }

  /// Sends one ContentDirectory action and returns the answer's text.
  /// Throws [DlnaFault] for a UPnP error.
  Future<String> call(Uri control, String action, Map<String, String> args, {Duration? timeout}) async {
    final response = await _http
        .post(
          control,
          headers: {"Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": soapActionHeader(action)},
          body: utf8.encode(buildSoapEnvelope(action, args)),
        )
        .timeout(timeout ?? _timeout);
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    final fault = parseFault(body);
    if (fault != null) throw fault;
    throw DlnaException("$action failed: HTTP ${response.statusCode}");
  }

  Future<DlnaBrowseResult> browse(
    Uri control,
    String objectId, {
    bool metadata = false,
    int start = 0,
    int count = 200,
    String sort = "",
  }) async {
    final text = await call(
      control,
      "Browse",
      browseArgs(objectId, metadata: metadata, start: start, count: count, sort: sort),
    );
    return parseBrowseResponse(text, base: control);
  }

  Future<DlnaBrowseResult> search(
    Uri control,
    String containerId,
    String criteria, {
    int start = 0,
    int count = 200,
  }) async {
    final text = await call(control, "Search", searchArgs(containerId, criteria, start: start, count: count));
    return parseBrowseResponse(text, base: control);
  }

  Future<Set<String>> searchCapabilities(Uri control) async => parseSearchCapabilities(
    await call(control, "GetSearchCapabilities", const {}, timeout: const Duration(seconds: 5)),
  );

  Future<void> ping(Uri control) async {
    await call(control, "GetSystemUpdateID", const {}, timeout: const Duration(seconds: 5));
  }

  void close() => _http.close();
}
