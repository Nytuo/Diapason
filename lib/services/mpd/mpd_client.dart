import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

class MpdClient {
  MpdClient({required this.host, required this.port, this.password});

  static final _log = Logger("MpdClient");

  final String host;
  final int port;
  final String? password;

  Socket? _socket;
  StreamSubscription<String>? _sub;
  String version = "";

  final Queue<_PendingCommand> _queue = Queue();
  _PendingCommand? _active;
  List<MapEntry<String, String>> _activeLines = [];

  bool get isConnected => _socket != null;

  Future<void> connect() async {
    if (_socket != null) return;
    final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    _socket = socket;
    final greeting = Completer<void>();
    _sub = utf8.decoder.bind(socket).transform(const LineSplitter()).listen(
      (line) => _onLine(line, greeting),
      onError: (Object e) {
        _log.warning("MPD socket error: $e");
        _failAll(e);
      },
      onDone: () {
        _log.info("MPD connection closed");
        _failAll(const SocketException("MPD connection closed"));
        _socket = null;
      },
    );
    await greeting.future.timeout(const Duration(seconds: 5));
    if (password != null && password!.isNotEmpty) {
      await command("password ${_quote(password!)}");
    }
  }

  void _onLine(String line, Completer<void>? greeting) {
    if (greeting != null && !greeting.isCompleted && line.startsWith("OK MPD ")) {
      version = line.substring(7).trim();
      greeting.complete();
      return;
    }
    final active = _active;
    if (active == null) return;

    if (line == "OK" || line.startsWith("OK MPD ")) {
      active.completer.complete(_activeLines);
      _finishActive();
      return;
    }
    if (line.startsWith("ACK ")) {
      active.completer.completeError(MpdException(line));
      _finishActive();
      return;
    }
    final idx = line.indexOf(": ");
    if (idx > 0) {
      _activeLines.add(MapEntry(line.substring(0, idx), line.substring(idx + 2)));
    }
  }

  void _finishActive() {
    _active = null;
    _activeLines = [];
    _pump();
  }

  void _pump() {
    if (_active != null || _queue.isEmpty) return;
    final socket = _socket;
    if (socket == null) {
      _failAll(const SocketException("Not connected"));
      return;
    }
    _active = _queue.removeFirst();
    _activeLines = [];
    socket.write("${_active!.command}\n");
  }

  void _failAll(Object error) {
    _active?.completer.completeError(error);
    _active = null;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().completer.completeError(error);
    }
  }

  Future<List<MapEntry<String, String>>> command(String cmd) {
    final pending = _PendingCommand(cmd);
    _queue.add(pending);
    _pump();
    return pending.completer.future;
  }

  Future<void> close() async {
    try {
      await _sub?.cancel();
      _socket?.destroy();
    } finally {
      _socket = null;
      _failAll(const SocketException("closed"));
    }
  }

  static List<Map<String, String>> group(List<MapEntry<String, String>> lines, Set<String> startKeys) {
    final out = <Map<String, String>>[];
    Map<String, String>? current;
    for (final line in lines) {
      if (startKeys.contains(line.key)) {
        current = {};
        out.add(current);
      }
      current?[line.key] = line.value;
    }
    return out;
  }

  static Map<String, String> single(List<MapEntry<String, String>> lines) => {for (final l in lines) l.key: l.value};

  static String _quote(String s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  static String quote(String s) => _quote(s);
}

class _PendingCommand {
  _PendingCommand(this.command);
  final String command;
  final Completer<List<MapEntry<String, String>>> completer = Completer();
}

class MpdException implements Exception {
  MpdException(this.message);
  final String message;
  @override
  String toString() => "MpdException: $message";
}
