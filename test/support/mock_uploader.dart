import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// One request the mock uploader received.
class UploaderRequest {
  UploaderRequest(this.method, this.uri, this.headers, [this.body = '']);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;
  String get path => uri.path;
}

/// A diapason-uploader look-alike on loopback, speaking the same /api/v1 protocol the app uses,
/// so the app's whole uploader path (settings screen, pairing, uploads, the YouTube proxy) can be
/// driven without Docker, Go or a network. The real server is covered by uploader_contract_test.dart.
class MockUploader {
  MockUploader({this.token = 'mock-token', this.ytdlp = true});

  final String token;
  bool ytdlp;
  bool pairing = true;
  bool pairingOpen = false;
  String issuedToken = 'device-token-1';

  /// Hashes of files "already in the library".
  final Set<String> library = {};
  final List<UploaderRequest> requests = [];
  final List<Map<String, dynamic>> uploads = [];
  final List<Map<String, dynamic>> downloads = [];

  /// How many polls a download job stays "running" before it finishes.
  int jobPolls = 1;

  /// When set, download jobs end in this error instead of "done".
  String? jobError;
  Duration latency = Duration.zero;

  late HttpServer _server;
  final Map<String, int> _polls = {};

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server.port}');

  List<UploaderRequest> calls(String path) => requests.where((r) => r.path == path).toList();

  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
    return baseUrl;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _json(HttpResponse r, int status, Object body) async {
    r.statusCode = status;
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode(body));
    await r.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    final body = latin1.decode(bytes);
    requests.add(
      UploaderRequest(req.method, req.uri, {
        for (final name in ['authorization', 'content-type'])
          if (req.headers.value(name) != null) name: req.headers.value(name)!,
      }, body),
    );
    if (latency > Duration.zero) await Future<void>.delayed(latency);

    final r = req.response;
    final path = req.uri.path;
    if (path == '/healthz') return _json(r, 200, {'ok': true});

    // Pairing is the one call that has no token yet.
    if (path == '/api/v1/pair' && req.method == 'POST') {
      if (!pairing || !pairingOpen) {
        return _json(r, 403, {'error': 'Pairing is closed.', 'code': 'pairing_closed', 'component': 'uploader'});
      }
      pairingOpen = false;
      return _json(r, 200, {'token': issuedToken});
    }

    final auth = req.headers.value('authorization');
    if (auth != 'Bearer $token' && auth != 'Bearer $issuedToken') {
      return _json(r, 401, {'error': 'invalid or missing token', 'code': 'unauthorized', 'component': 'auth'});
    }

    switch ((req.method, path)) {
      case ('GET', '/api/v1/capabilities'):
        return _json(r, 200, {
          'ytdlp': ytdlp,
          if (ytdlp) 'ytdlpVersion': '2099.01.01',
          if (ytdlp) 'ytdlpJsRuntime': 'deno',
          'ytdlpTagging': ytdlp,
          'pairing': pairing,
        });
      case ('POST', '/api/v1/pair/open'):
        pairingOpen = true;
        return _json(r, 200, {'open': true});
      case ('GET', '/api/v1/exists'):
        return _json(r, 200, {'exists': library.contains(req.uri.queryParameters['hash'])});
      case ('POST', '/api/v1/upload'):
        final meta = RegExp(r'name="metadata"[\s\S]*?\r\n\r\n(\{[\s\S]*?\})\r\n--').firstMatch(body)?.group(1);
        final data = meta == null ? <String, dynamic>{} : jsonDecode(meta) as Map<String, dynamic>;
        final fileBody = RegExp(r'name="file"[\s\S]*?\r\n\r\n([\s\S]*?)\r\n--').firstMatch(body)?.group(1) ?? '';
        final hash = sha256.convert(latin1.encode(fileBody)).toString();
        if (library.contains(hash)) return _json(r, 409, {'error': 'duplicate', 'code': 'duplicate'});
        library.add(hash);
        uploads.add({...data, 'hash': hash, 'bytes': fileBody.length});
        return _json(r, 201, {'stored': true});
      case ('GET', '/api/v1/ytdlp/search'):
        if (!ytdlp) return _off(r);
        final q = req.uri.queryParameters['q'] ?? '';
        return _json(r, 200, {
          'results': [
            {'id': 'aaaaaaaaaaa', 'title': 'Result for $q', 'artist': 'Mock Artist', 'durationSecs': 215},
            {'id': 'bbbbbbbbbbb', 'title': 'Second for $q', 'artist': 'Other Artist', 'durationSecs': 180},
          ],
        });
      case ('GET', '/api/v1/ytdlp/trending'):
        if (!ytdlp) return _off(r);
        return _json(r, 200, {
          'results': [
            {'id': 'ccccccccccc', 'title': 'Trending One', 'artist': 'Hit Maker', 'durationSecs': 200},
          ],
        });
      case ('GET', '/api/v1/ytdlp/related'):
        if (!ytdlp) return _off(r);
        return _json(r, 200, {
          'results': [
            {'id': 'ddddddddddd', 'title': 'Related', 'artist': 'Similar', 'durationSecs': 190},
          ],
        });
      case ('POST', '/api/v1/ytdlp/download'):
        if (!ytdlp) return _off(r);
        final job = jsonDecode(body) as Map<String, dynamic>;
        downloads.add(job);
        final id = 'job${downloads.length}';
        _polls[id] = 0;
        return _json(r, 202, {'id': id});
    }

    if (path.startsWith('/api/v1/ytdlp/jobs/')) {
      final id = path.split('/').last;
      final seen = _polls[id] = (_polls[id] ?? 0) + 1;
      if (seen <= jobPolls) return _json(r, 200, {'state': 'running'});
      if (jobError != null) {
        return _json(r, 200, {
          'state': 'error',
          'error': jobError,
          'code': 'youtube_blocked',
          'detail': 'Sign in to confirm you are not a bot',
        });
      }
      return _json(r, 200, {'state': 'done', 'duplicate': false});
    }
    if (path.startsWith('/api/v1/ytdlp/thumb/')) {
      r.headers.contentType = ContentType('image', 'png');
      r.add(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
        ),
      );
      return r.close();
    }
    if (path.startsWith('/api/v1/ytdlp/stream/')) {
      r.headers.contentType = ContentType('audio', 'mpeg');
      r.add(List.filled(2048, 0));
      return r.close();
    }
    return _json(r, 404, {'error': 'not found', 'code': 'not_found'});
  }

  Future<void> _off(HttpResponse r) => _json(r, 503, {
    'error': 'YouTube is switched off on this server.',
    'code': 'ytdlp_disabled',
    'component': 'ytdlp',
  });
}
