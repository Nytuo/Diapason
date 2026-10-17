import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/youtube/yt_entry.dart';
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

class UploadResult {
  const UploadResult.stored() : ok = true, duplicate = false, message = null, source = null;
  const UploadResult.duplicate() : ok = true, duplicate = true, message = null, source = null;
  const UploadResult.failed(this.message, {this.source}) : ok = false, duplicate = false;

  final bool ok;
  final bool duplicate;

  final String? message;

  final ErrorSource? source;
}

enum UploaderState { unconfigured, ok, unreachable, unauthorized, notAnUploader }

class UploaderCapabilities {
  const UploaderCapabilities({
    this.state = UploaderState.ok,
    this.problem,
    this.ytdlp = false,
    this.ytdlpVersion,
    this.jsRuntime,
    this.tagging = false,
    this.pairing = false,
  });

  static const none = UploaderCapabilities(state: UploaderState.unconfigured);

  final UploaderState state;

  final String? problem;
  final bool ytdlp;
  final String? ytdlpVersion;

  final String? jsRuntime;
  final bool tagging;
  final bool pairing;

  bool get reachable => state == UploaderState.ok;
}

class UploaderException extends AppException {
  const UploaderException(
    super.message, {
    super.source = ErrorSource.uploader,
    super.code,
    super.detail,
    super.requestId,
  });
}

class UploaderClient {
  UploaderClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("UploaderClient");

  static const _audioExtensions = {
    "mp3", "m4a", "aac", "flac", "ogg", "oga", "opus", "wav", "wma", "aiff", "aif", "alac", "webm", "mka", "mp4",
    "wv", "ape", //
  };

  static List<String> get audioExtensions => _audioExtensions.toList()..sort();

  final http.Client _http;

  bool get enabled => FinampSettingsHelper.finampSettings.uploaderEnabled;
  String get baseUrl => FinampSettingsHelper.finampSettings.uploaderUrl.trim();
  String get token => FinampSettingsHelper.finampSettings.uploaderToken.trim();
  UploaderNetworkPolicy get policy =>
      UploaderNetworkPolicy.fromName(FinampSettingsHelper.finampSettings.uploaderNetworkPolicy);

  bool get isConfigured => baseUrl.isNotEmpty && isAllowed(baseUrl, policy, allowInsecure: allowInsecure);

  bool get allowInsecure => FinampSettingsHelper.finampSettings.uploaderAllowInsecure;

  bool get isReady => enabled && isConfigured;

  bool get proxyActive => FinampSettingsHelper.finampSettings.uploaderYtProxy && isConfigured;

  static bool isPrivateHost(String host) {
    host = host.toLowerCase();
    if (host.isEmpty) return false;
    if (host == "localhost" || host.endsWith(".local") || host.endsWith(".localhost")) return true;

    if (host.endsWith(".ts.net") || host.endsWith(".home.arpa") || host.endsWith(".internal")) return true;

    final address = InternetAddress.tryParse(host);
    if (address == null) return false;

    if (address.type == InternetAddressType.IPv4) {
      final octets = address.rawAddress;
      if (octets[0] == 127 || octets[0] == 10) return true;
      if (octets[0] == 192 && octets[1] == 168) return true;
      if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
      if (octets[0] == 169 && octets[1] == 254) return true;

      if (octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127) return true;
      return false;
    }

    if (address.isLoopback) return true;

    final first = address.rawAddress.first;
    return (first & 0xFE) == 0xFC || (first == 0xFE && (address.rawAddress[1] & 0xC0) == 0x80);
  }

  static String? blockReason(String url, UploaderNetworkPolicy policy, {bool allowInsecure = false}) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty || (uri.scheme != "http" && uri.scheme != "https")) {
      return "Enter a full address such as https://music.example.com";
    }
    final private = isPrivateHost(uri.host);
    if (!private && uri.scheme != "https" && !allowInsecure) {
      return "Addresses outside your local network or VPN must use https://, or tick “My connection is already secure”.";
    }
    if (policy == UploaderNetworkPolicy.local && !private) {
      return "That address isn't on the local network. Switch to “Anywhere” to allow it.";
    }
    return null;
  }

  static bool isAllowed(String url, UploaderNetworkPolicy policy, {bool allowInsecure = false}) =>
      blockReason(url, policy, allowInsecure: allowInsecure) == null;

  bool get isCleartext => Uri.tryParse(baseUrl)?.scheme == "http";

  Uri _endpoint(String path, [Map<String, String>? query]) {
    var base = baseUrl;
    while (base.endsWith("/")) {
      base = base.substring(0, base.length - 1);
    }
    final uri = Uri.parse("$base/$path");
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Map<String, String> get authHeaders => token.isEmpty ? const {} : {"Authorization": "Bearer $token"};

  Future<bool> automaticTransferAllowed() async {
    if (!FinampSettingsHelper.finampSettings.uploaderWifiOnly) return true;
    try {
      final connections = await Connectivity().checkConnectivity();
      final ok = connections.any(
        (c) => c == ConnectivityResult.wifi || c == ConnectivityResult.ethernet || c == ConnectivityResult.vpn,
      );
      if (!ok) _log.info("Skipping an automatic upload: Wi-Fi only is on and this isn't Wi-Fi/Ethernet ($connections)");
      return ok;
    } catch (e) {
      _log.fine("Couldn't read the connection type; allowing the transfer: $e");
      return true;
    }
  }

  UploaderException _fromResponse(String what, http.Response response) {
    final status = response.statusCode;
    final requestId = response.headers["x-request-id"];
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}

    final code = body?["code"] as String?;
    final component = body?["component"] as String?;
    final detail = body?["detail"] as String?;
    var message = body?["error"] as String?;
    var source = switch (component) {
      "ytdlp" => ErrorSource.ytdlp,
      "uploader" || "auth" || "pairing" => ErrorSource.uploader,
      _ => ErrorSource.uploader,
    };

    if (body == null) {
      source = ErrorSource.connection;
      message = switch (status) {
        502 ||
        503 ||
        504 ||
        521 ||
        522 ||
        523 ||
        524 => "Your reverse proxy or tunnel is up, but the uploader behind it isn't answering (HTTP $status).",
        404 => "That address answered, but it doesn't look like a diapason-uploader (or it's too old).",
        413 => "A proxy in front of the uploader rejected the file as too large.",
        _ => "The address answered with HTTP $status, which isn't what the uploader sends.",
      };
    } else if (status == 401) {
      message =
          "The uploader didn't accept this device's token. Pair again, or paste a valid token in the uploader settings.";
    } else if (status == 501 && code == "ytdlp_disabled") {
      message = "Your uploader has its YouTube feature turned off (set DIAPASON_YTDLP_ENABLED=true on it).";
    }

    final exception = UploaderException(
      message ?? "The uploader answered HTTP $status.",
      source: source,
      code: code ?? "http_$status",
      detail: detail ?? (body == null ? "HTTP $status" : null),
      requestId: requestId,
    );
    _log.warning("$what -> HTTP $status [${exception.technical}]");
    return exception;
  }

  UploaderException _fromTransport(String what, Object error, StackTrace stack) {
    final d = FriendlyError.describe(error);
    _log.warning("$what failed [${d.source.name}]: ${d.technical}", error, stack);
    return UploaderException(d.message, source: ErrorSource.connection, code: "unreachable", detail: d.technical);
  }

  Future<http.Response> _call(
    String what,
    Future<http.Response> Function() send, {
    Duration timeout = const Duration(seconds: 30),
    Set<int> accept = const {},
  }) async {
    final http.Response response;
    try {
      response = await send().timeout(timeout);
    } on UploaderException {
      rethrow;
    } catch (e, stack) {
      throw _fromTransport(what, e, stack);
    }
    if (response.statusCode >= 200 && response.statusCode < 300 || accept.contains(response.statusCode)) {
      return response;
    }
    throw _fromResponse(what, response);
  }

  Future<Map<String, dynamic>> _getJson(String what, Uri uri, {Duration timeout = const Duration(seconds: 60)}) async {
    final response = await _call(what, () => _http.get(uri, headers: authHeaders), timeout: timeout);
    try {
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      throw UploaderException(
        "The uploader sent a reply the app couldn't read. It may be too old for this version of Diapason.",
        code: "bad_response",
        detail: "$e",
        requestId: response.headers["x-request-id"],
      );
    }
  }

  Future<UploaderCapabilities> capabilities() async {
    if (baseUrl.isEmpty) return UploaderCapabilities.none;
    final reason = blockReason(baseUrl, policy, allowInsecure: allowInsecure);
    if (reason != null) {
      return UploaderCapabilities(state: UploaderState.unconfigured, problem: reason);
    }
    try {
      final body = await _getJson(
        "capabilities",
        _endpoint("api/v1/capabilities"),
        timeout: const Duration(seconds: 10),
      );
      return UploaderCapabilities(
        ytdlp: body["ytdlp"] == true,
        ytdlpVersion: body["ytdlpVersion"] as String?,
        jsRuntime: (body["ytdlpJsRuntime"] as String?)?.isEmpty ?? true ? null : body["ytdlpJsRuntime"] as String?,
        tagging: body["ytdlpTagging"] == true,
        pairing: body["pairing"] == true,
      );
    } on UploaderException catch (e) {
      final state = switch (e.code) {
        "unauthorized" => UploaderState.unauthorized,
        "unreachable" => UploaderState.unreachable,
        "bad_response" || "http_404" => UploaderState.notAnUploader,
        _ => e.source == ErrorSource.connection ? UploaderState.unreachable : UploaderState.notAnUploader,
      };
      return UploaderCapabilities(state: state, problem: e.message);
    }
  }

  Future<String?> testConnection() async => (await capabilities()).problem;

  Future<String> pair(String url, String deviceName) async {
    final reason = blockReason(url, UploaderNetworkPolicy.internet, allowInsecure: allowInsecure);
    if (reason != null) throw UploaderException(reason, source: ErrorSource.connection, code: "blocked_address");
    var base = url.trim();
    while (base.endsWith("/")) {
      base = base.substring(0, base.length - 1);
    }
    final response = await _call(
      "pair",
      () => _http.post(
        Uri.parse("$base/api/v1/pair"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"name": deviceName}),
      ),
      timeout: const Duration(seconds: 10),
    );
    return (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)["token"] as String;
  }

  Future<void> openPairing() async {
    await _call(
      "open pairing",
      () => _http.post(_endpoint("api/v1/pair/open"), headers: authHeaders),
      timeout: const Duration(seconds: 10),
    );
  }

  Future<bool> exists(String sha256Hash) async {
    try {
      final body = await _getJson(
        "exists",
        _endpoint("api/v1/exists", {"hash": sha256Hash}),
        timeout: const Duration(seconds: 15),
      );
      return body["exists"] == true;
    } on UploaderException {
      return false;
    }
  }

  Future<bool> upload(BaseItemDto item, File file) async {
    if (!isReady) return false;
    final result = await uploadFile(
      file,
      artist: item.albumArtist ?? item.artists?.firstOrNull ?? "",
      album: item.album ?? "",
      title: item.name ?? "",
      trackNumber: item.indexNumber ?? 0,
      discNumber: item.parentIndexNumber ?? 0,
      year: item.productionYear ?? 0,
    );
    return result.ok;
  }

  Future<UploadResult> uploadFile(
    File file, {
    String artist = "",
    String album = "",
    String title = "",
    int trackNumber = 0,
    int discNumber = 0,
    int year = 0,
  }) async {
    if (!isConfigured) {
      return const UploadResult.failed(
        "The uploader address isn't usable. Check its settings.",
        source: ErrorSource.uploader,
      );
    }
    if (!file.existsSync()) {
      return const UploadResult.failed("That file no longer exists on this device.", source: ErrorSource.device);
    }

    final extension = p.extension(file.path).replaceFirst(".", "").toLowerCase();
    if (extension.isNotEmpty && !_audioExtensions.contains(extension)) {
      return UploadResult.failed(
        "“.$extension” isn't an audio format the uploader accepts.",
        source: ErrorSource.device,
      );
    }

    try {
      final hash = (await sha256.bind(file.openRead()).first).toString();
      if (await exists(hash)) {
        _log.fine("Uploader already has '$title'");
        return const UploadResult.duplicate();
      }

      final metadata = {
        "artist": artist,
        "album": album,
        "title": title.isNotEmpty ? title : p.basenameWithoutExtension(file.path),
        "trackNumber": trackNumber,
        "discNumber": discNumber,
        "year": year,
        "ext": extension.isEmpty ? "m4a" : extension,
      };

      final request = http.MultipartRequest("POST", _endpoint("api/v1/upload"))
        ..headers.addAll(authHeaders)
        ..files.add(
          http.MultipartFile.fromString(
            "metadata",
            jsonEncode(metadata),
            contentType: MediaType("application", "json"),
          ),
        )
        ..files.add(
          http.MultipartFile(
            "file",
            file.openRead(),
            await file.length(),
            filename: "track.${metadata["ext"]}",
            contentType: MediaType("application", "octet-stream"),
          ),
        );

      final response = await http.Response.fromStream(await _http.send(request));
      if (response.statusCode == 409) return const UploadResult.duplicate();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _log.info("Uploaded '$title' to the library");
        return const UploadResult.stored();
      }
      final e = _fromResponse("upload '$title'", response);
      return UploadResult.failed(e.message, source: e.source);
    } on UploaderException catch (e) {
      return UploadResult.failed(e.message, source: e.source);
    } catch (e, stack) {
      final ex = _fromTransport("upload '$title'", e, stack);
      return UploadResult.failed(ex.message, source: ex.source);
    }
  }

  List<YtEntry> _entries(Map<String, dynamic> body) =>
      (body["results"] as List? ?? const []).map((e) => YtEntry.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<YtEntry>> ytSearch(String query, {int limit = 20}) async =>
      _entries(await _getJson("yt search", _endpoint("api/v1/ytdlp/search", {"q": query, "limit": "$limit"})));

  Future<List<YtEntry>> ytTrending({int limit = 30}) async =>
      _entries(await _getJson("yt trending", _endpoint("api/v1/ytdlp/trending", {"limit": "$limit"})));

  Future<List<YtEntry>> ytRelated(String videoId, {int limit = 20}) async =>
      _entries(await _getJson("yt related", _endpoint("api/v1/ytdlp/related", {"id": videoId, "limit": "$limit"})));

  Uri ytThumbnail(String videoId) => _endpoint("api/v1/ytdlp/thumb/$videoId");

  Uri ytStream(String videoId) => _endpoint("api/v1/ytdlp/stream/$videoId");

  Future<UploadResult> ytDownloadToLibrary(
    String videoId, {
    String? artist,
    String? album,
    String? title,
    Duration timeout = const Duration(minutes: 10),
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    try {
      final response = await _call(
        "yt download",
        () => _http.post(
          _endpoint("api/v1/ytdlp/download"),
          headers: {...authHeaders, "Content-Type": "application/json"},
          body: jsonEncode({
            "id": videoId,
            if (artist != null && artist.isNotEmpty) "artist": artist,
            if (album != null && album.isNotEmpty) "album": album,
            if (title != null && title.isNotEmpty) "title": title,
          }),
        ),
        timeout: const Duration(seconds: 30),
        accept: const {202},
      );
      final jobId = (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)["id"] as String;

      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        final job = await _getJson(
          "yt job",
          _endpoint("api/v1/ytdlp/jobs/$jobId"),
          timeout: const Duration(seconds: 15),
        );
        switch (job["state"]) {
          case "done":
            return job["duplicate"] == true ? const UploadResult.duplicate() : const UploadResult.stored();
          case "error":
            _log.warning("Server-side download of $videoId failed: code=${job["code"]} detail=${job["detail"]}");
            return UploadResult.failed(
              (job["error"] as String?) ?? "The server couldn't download that track.",
              source: ErrorSource.ytdlp,
            );
        }
      }
      return const UploadResult.failed(
        "The server is still working on it. Check your library in a bit.",
        source: ErrorSource.uploader,
      );
    } on UploaderException catch (e) {
      return UploadResult.failed(e.message, source: e.source);
    }
  }
}
