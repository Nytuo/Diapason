import 'dart:async';
import 'dart:convert';
import 'dart:io';






class UploaderProcess {
  UploaderProcess._(this._process, this.baseUrl, this.token, this.musicDir, this.stateDir, this.log);

  final Process _process;
  final Uri baseUrl;
  final String token;
  final Directory musicDir;
  final Directory stateDir;
  final StringBuffer log;

  static const defaultToken = 'contract-test-token-0123456789abcdef';

  static String? _builtBinary;


  static Future<String?> unavailableReason() async {
    if (Platform.environment['DIAPASON_UPLOADER_BIN'] != null) return null;
    final dir = _sourceDir();
    if (dir == null) return 'no diapason-uploader source found (set DIAPASON_UPLOADER_DIR)';
    final go = await Process.run('go', ['version']);
    if (go.exitCode != 0) return 'the Go toolchain is not installed';
    return null;
  }

  static Directory? _sourceDir() {
    final fromEnv = Platform.environment['DIAPASON_UPLOADER_DIR'];
    final candidates = [if (fromEnv != null) fromEnv, '../diapason-uploader'];
    for (final c in candidates) {
      if (File('$c/main.go').existsSync()) return Directory(c);
    }
    return null;
  }


  static Future<String> build(Directory scratch) async {
    final prebuilt = Platform.environment['DIAPASON_UPLOADER_BIN'];
    if (prebuilt != null) return prebuilt;
    if (_builtBinary != null && File(_builtBinary!).existsSync()) return _builtBinary!;
    final out = '${scratch.path}/diapason-uploader';
    final result = await Process.run('go', ['build', '-o', out, '.'], workingDirectory: _sourceDir()!.path);
    if (result.exitCode != 0) throw StateError('go build failed:\n${result.stdout}\n${result.stderr}');
    return _builtBinary = out;
  }

  static Future<UploaderProcess> start(
    String binary,
    Directory root, {
    String token = defaultToken,
    Map<String, String> env = const {},
  }) async {
    final music = await Directory('${root.path}/music').create(recursive: true);
    final state = await Directory('${root.path}/state').create(recursive: true);
    final work = await Directory('${root.path}/work').create(recursive: true);
    final port = await _freePort();

    final process = await Process.start(
      binary,
      const [],
      environment: {
        'DIAPASON_MUSIC_DIR': music.path,
        'DIAPASON_STATE_DIR': state.path,
        'DIAPASON_WORK_DIR': work.path,
        'DIAPASON_LISTEN_ADDR': '127.0.0.1:$port',
        'DIAPASON_AUTH_TOKEN': token,
        'DIAPASON_MDNS_ENABLED': 'false',
        'DIAPASON_PLAIN_HTTP_OK': 'true',
        'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
        ...env,
      },
      includeParentEnvironment: false,
    );
    final log = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(log.write);
    process.stderr.transform(utf8.decoder).listen(log.write);

    final base = Uri.parse('http://127.0.0.1:$port');
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      try {
        final client = HttpClient();
        final request = await client.getUrl(base.resolve('/healthz'));
        final response = await request.close();
        await response.drain<void>();
        client.close();
        if (response.statusCode == 200) break;
      } catch (_) {}
      if (DateTime.now().isAfter(deadline)) {
        process.kill();
        throw StateError('uploader did not start:\n$log');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return UploaderProcess._(process, base, token, music, state, log);
  }

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }


  Future<({int status, Map<String, String> headers, String body})> raw(
    String method,
    String path, {
    Map<String, String> headers = const {},
    Object? body,
    String? authToken,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, baseUrl.resolve(path));
      final bearer = authToken ?? token;
      if (bearer.isNotEmpty) request.headers.set('Authorization', 'Bearer $bearer');
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      final out = <String, String>{};
      response.headers.forEach((name, values) => out[name] = values.join(','));
      return (status: response.statusCode, headers: out, body: text);
    } finally {
      client.close();
    }
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}
