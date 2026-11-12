// Diapason: a loopback HTTP server that runs in its own isolate. It downloads
// a remote file into the cache and serves the finished file (with range
// support) to the native player, so neither the download nor the streaming of
// a whole FLAC to AVFoundation touches the UI isolate. Only small progress
// messages cross back to the main isolate.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// Progress report from the server isolate.
class BackgroundCacheProgress {
  final String id;
  final int received;
  final int? total;
  final bool done;
  final String? error;
  const BackgroundCacheProgress(this.id, this.received, this.total,
      {this.done = false, this.error});
}

/// Client side, living in the main isolate.
class BackgroundCacheServer {
  BackgroundCacheServer._();
  static final BackgroundCacheServer instance = BackgroundCacheServer._();

  SendPort? _commands;
  int? _port;
  Future<void>? _starting;
  final _listeners = <String, void Function(BackgroundCacheProgress)>{};

  Future<void> _ensureRunning() => _starting ??= _start();

  Future<void> _start() async {
    final handshake = ReceivePort();
    await Isolate.spawn(_serverMain, handshake.sendPort,
        debugName: 'just_audio background cache server');
    final reply = await handshake.first as List;
    handshake.close();
    _commands = reply[0] as SendPort;
    _port = reply[1] as int;
    final progress = ReceivePort();
    _commands!.send(['progress-port', progress.sendPort]);
    progress.listen((message) {
      final m = message as BackgroundCacheProgress;
      _listeners[m.id]?.call(m);
    });
  }

  /// Registers a download and returns the URL the native player should load.
  Future<Uri> register({
    required String id,
    required Uri remote,
    required Map<String, String>? headers,
    required String cachePath,
    required String? userAgent,
    required void Function(BackgroundCacheProgress) onProgress,
  }) async {
    try {
      await _ensureRunning();
    } catch (_) {
      _starting = null;
      rethrow;
    }
    _listeners[id] = onProgress;
    _commands!.send([
      'register',
      id,
      remote.toString(),
      headers,
      cachePath,
      userAgent,
    ]);
    return Uri.parse('http://127.0.0.1:$_port/$id');
  }

  void unregister(String id) {
    _listeners.remove(id);
    _commands?.send(['unregister', id]);
  }
}

class _Entry {
  final String id;
  final Uri remote;
  final Map<String, String>? headers;
  final File file;
  final String? userAgent;
  String contentType = 'audio/flac';
  Future<void>? download;
  _Entry(this.id, this.remote, this.headers, this.file, this.userAgent);
}

Future<void> _serverMain(SendPort handshake) async {
  final commands = ReceivePort();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  handshake.send([commands.sendPort, server.port]);

  final entries = <String, _Entry>{};
  SendPort? progressPort;

  Future<void> download(_Entry e) async {
    final part = File('${e.file.path}.part');
    final client = HttpClient();
    if (e.userAgent != null) client.userAgent = e.userAgent;
    IOSink? sink;
    try {
      final request = await client.getUrl(e.remote);
      final headers = e.headers;
      if (headers != null) {
        headers.forEach((name, value) => request.headers.set(name, value));
      }
      request.maxRedirects = 20;
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP status ${response.statusCode}', uri: e.remote);
      }
      e.contentType = response.headers.contentType?.toString() ?? e.contentType;
      final total = response.contentLength < 0 ? null : response.contentLength;
      part.createSync(recursive: true);
      sink = part.openWrite();
      var received = 0;
      var lastPercent = -1;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        final percent = total == null ? 0 : (100 * received ~/ total);
        if (percent != lastPercent) {
          lastPercent = percent;
          progressPort?.send(BackgroundCacheProgress(e.id, received, total));
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      part.renameSync(e.file.path);
      progressPort?.send(BackgroundCacheProgress(e.id, received, total, done: true));
    } catch (error) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      progressPort?.send(BackgroundCacheProgress(e.id, 0, null, error: '$error'));
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    try {
      final id = request.uri.pathSegments.isEmpty ? '' : request.uri.pathSegments.first;
      final entry = entries[id];
      if (entry == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (!entry.file.existsSync()) {
        // A failed download is retried by the next request.
        await (entry.download ??= download(entry).whenComplete(() {
          if (!entry.file.existsSync()) entry.download = null;
        }));
      }
      final length = entry.file.lengthSync();
      var start = 0;
      var end = length; // exclusive
      var partial = false;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
        if (match != null) {
          final from = match.group(1)!;
          final to = match.group(2)!;
          if (from.isEmpty && to.isNotEmpty) {
            start = (length - int.parse(to)).clamp(0, length);
          } else if (from.isNotEmpty) {
            start = int.parse(from);
            if (to.isNotEmpty) end = (int.parse(to) + 1).clamp(0, length);
          }
          partial = true;
        }
      }
      if (start >= length && length > 0 && partial) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, entry.contentType);
      response.contentLength = end - start;
      if (partial) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/$length');
      }
      if (request.method != 'HEAD') {
        await response.addStream(entry.file.openRead(start, end));
      }
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  server.listen(serve);

  commands.listen((message) {
    final m = message as List;
    switch (m[0]) {
      case 'progress-port':
        progressPort = m[1] as SendPort;
      case 'register':
        final id = m[1] as String;
        entries[id] = _Entry(
          id,
          Uri.parse(m[2] as String),
          (m[3] as Map?)?.cast<String, String>(),
          File(m[4] as String),
          m[5] as String?,
        );
      case 'unregister':
        entries.remove(m[1] as String);
    }
  });
}
