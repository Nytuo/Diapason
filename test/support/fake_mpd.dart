import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A tiny MPD server on loopback: greets, answers one command per line from [replies]
/// (keyed by exact command or a prefix), and records what it was asked.
class FakeMpd {
  FakeMpd._(this._server);

  final ServerSocket _server;
  final List<String> commands = [];
  final List<Socket> _clients = [];

  /// Command (or command prefix) → response lines, without the final OK.
  final Map<String, List<String>> replies = {};

  /// Commands answered with `ACK [...]`.
  final Set<String> failing = {};

  /// If set, the greeting is withheld (for the timeout path).
  bool silent = false;

  int get port => _server.port;

  static Future<FakeMpd> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final mpd = FakeMpd._(server);
    server.listen(mpd._onClient);
    return mpd;
  }

  void _onClient(Socket socket) {
    _clients.add(socket);
    if (!silent) socket.write('OK MPD 0.23.5\n');
    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          (line) {
            commands.add(line);
            if (failing.any(line.startsWith)) {
              socket.write('ACK [50@0] {$line} nope\n');
              return;
            }
            final key = replies.containsKey(line) ? line : replies.keys.where(line.startsWith).firstOrNull;
            final body = key == null ? const <String>[] : replies[key]!;
            socket.write('${body.map((l) => '$l\n').join()}OK\n');
          },
          onError: (_) {},
          onDone: () => _clients.remove(socket),
        );
  }

  /// Drops every connection, as if the daemon restarted.
  void dropClients() {
    for (final c in List.of(_clients)) {
      c.destroy();
    }
    _clients.clear();
  }

  Future<void> stop() async {
    dropClients();
    await _server.close();
  }
}
