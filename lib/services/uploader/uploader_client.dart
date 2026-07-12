import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

enum UploaderNetworkPolicy {
  local,
  internet;

  static UploaderNetworkPolicy fromName(String name) =>
      UploaderNetworkPolicy.values.firstWhere((p) => p.name == name, orElse: () => UploaderNetworkPolicy.local);
}

class UploaderClient {
  UploaderClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("UploaderClient");

  final http.Client _http;

  bool get enabled => FinampSettingsHelper.finampSettings.uploaderEnabled;
  String get baseUrl => FinampSettingsHelper.finampSettings.uploaderUrl.trim();
  String get token => FinampSettingsHelper.finampSettings.uploaderToken;
  UploaderNetworkPolicy get policy =>
      UploaderNetworkPolicy.fromName(FinampSettingsHelper.finampSettings.uploaderNetworkPolicy);

  bool get isReady => enabled && baseUrl.isNotEmpty && isAllowed(baseUrl, policy);

  static bool isAllowed(String url, UploaderNetworkPolicy policy) {
    if (policy == UploaderNetworkPolicy.internet) return true;

    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return false;

    if (host == "localhost" || host.endsWith(".local")) return true;

    final address = InternetAddress.tryParse(host);
    if (address == null) return false;

    if (address.type == InternetAddressType.IPv4) {
      final octets = address.rawAddress;
      if (octets[0] == 127 || octets[0] == 10) return true;
      if (octets[0] == 192 && octets[1] == 168) return true;
      if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
      return false;
    }

    if (address.isLoopback) return true;
    return (address.rawAddress.first & 0xFE) == 0xFC;
  }

  Uri _endpoint(String path) {
    var base = baseUrl;
    while (base.endsWith("/")) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.parse("$base/$path");
  }

  Map<String, String> get _authHeaders => token.isEmpty ? const {} : {"Authorization": "Bearer $token"};

  Future<bool> exists(String sha256Hash) async {
    try {
      final response = await _http.get(
        _endpoint("api/v1/exists").replace(queryParameters: {"hash": sha256Hash}),
        headers: _authHeaders,
      );
      if (response.statusCode != 200) return false;
      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return body["exists"] == true;
    } catch (e) {
      _log.fine("Uploader exists-check failed: $e");
      return false;
    }
  }

  Future<bool> upload(BaseItemDto item, File file) async {
    if (!isReady) return false;
    if (!file.existsSync()) return false;

    try {
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      if (await exists(hash)) {
        _log.fine("Uploader already has '${item.name}'");
        return true;
      }

      final extension = p.extension(file.path).replaceFirst(".", "");
      final metadata = {
        "artist": item.albumArtist ?? item.artists?.firstOrNull ?? "",
        "album": item.album ?? "",
        "title": item.name ?? "",
        "trackNumber": item.indexNumber ?? 0,
        "discNumber": item.parentIndexNumber ?? 0,
        "year": item.productionYear ?? 0,
        "ext": extension.isEmpty ? "m4a" : extension,
      };

      final request = http.MultipartRequest("POST", _endpoint("api/v1/upload"))
        ..headers.addAll(_authHeaders)
        ..files.add(
          http.MultipartFile.fromString(
            "metadata",
            jsonEncode(metadata),
            contentType: MediaType("application", "json"),
          ),
        )
        ..files.add(
          http.MultipartFile.fromBytes(
            "file",
            bytes,
            filename: "track.${metadata["ext"]}",
            contentType: MediaType("application", "octet-stream"),
          ),
        );

      final response = await http.Response.fromStream(await _http.send(request));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _log.info("Uploaded '${item.name}' to the library");
        return true;
      }
      _log.warning("Uploader rejected '${item.name}': HTTP ${response.statusCode}");
      return false;
    } catch (e) {
      _log.warning("Could not upload '${item.name}': $e");
      return false;
    }
  }
}
