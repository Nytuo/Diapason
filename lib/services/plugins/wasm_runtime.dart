import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:diapason/services/plugins/plugin_host.dart';
import 'package:diapason/services/plugins/plugin_runtime.dart';
import 'package:wasd/wasd.dart';

/// Runs a WebAssembly plugin with WASD, a WebAssembly interpreter written in Dart, in its own isolate.
///
/// - Nothing native is loaded: the module is interpreted, so it runs the same on iOS, tvOS and everywhere else, and
///   it can only reach the two host functions it is given (`diapason.host_call` / `diapason.host_result`). Those go
///   to [PluginHostBridge.handle] on the main isolate, which checks permissions.
/// - The isolate is the crash boundary: a call that runs past [callTimeout] (an endless loop included) kills it, a
///   trap discards the instance, and the next call starts a fresh one. After [maxConsecutiveFailures] failures in a
///   row the plugin is suspended until it is re-enabled.
class WasmRuntime implements PluginRuntime {
  WasmRuntime({
    required Uint8List module,
    required this.bridge,
    this.callTimeout = const Duration(seconds: 20),
    this.maxConsecutiveFailures = 5,
  }) : _module = module;

  static const maxMemoryBytes = 64 * 1024 * 1024;
  static const maxMessageBytes = 4 * 1024 * 1024;

  final Uint8List _module;
  final PluginHostBridge bridge;
  final Duration callTimeout;
  final int maxConsecutiveFailures;

  Isolate? _isolate;
  ReceivePort? _port;
  SendPort? _toWorker;
  Completer<void>? _starting;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;
  var _failures = 0;
  var _disposed = false;

  /// Set once the plugin failed too often; calls are refused until a new runtime is made.
  String? suspendedReason;

  /// Checks that [bytes] is a module this runtime can run: valid WebAssembly with the exports the ABI needs.
  static Future<void> validate(Uint8List view) async {
    // The view may be a slice of a bigger buffer (e.g. the unpacked zip); WASD reads whole buffers.
    final bytes = Uint8List.fromList(view);
    if (!WebAssembly.validate(bytes.buffer)) throw PluginCallException("plugin.wasm is not a valid WebAssembly module");
    final module = await WebAssembly.compile(bytes.buffer);
    final exports = {for (final e in Module.exports(module)) e.name};
    for (final name in const ["memory", "diapason_alloc", "diapason_handle"]) {
      if (!exports.contains(name)) throw PluginCallException("plugin.wasm does not export '$name'");
    }
    final imports = Module.imports(module);
    for (final import in imports) {
      if (import.module != "diapason" || !const {"host_call", "host_result"}.contains(import.name)) {
        throw PluginCallException(
          "plugin.wasm imports '${import.module}.${import.name}', which Diapason does not provide",
        );
      }
    }
  }

  Future<void> _start() async {
    if (_toWorker != null) return;
    if (_starting != null) return _starting!.future;
    final starting = _starting = Completer<void>();
    final port = _port = ReceivePort();
    port.listen(_onMessage);
    try {
      _isolate = await Isolate.spawn(
        _workerMain,
        (port.sendPort, TransferableTypedData.fromList([_module])),
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
        debugName: "plugin:${bridge.pluginId}",
      );
    } catch (e) {
      _teardown("could not start: $e");
      rethrow;
    }
    await starting.future.timeout(
      callTimeout,
      onTimeout: () {
        _teardown("did not start in time");
        throw PluginCallException("the plugin did not start in time");
      },
    );
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _toWorker = message;
      _starting?.complete();
      _starting = null;
      return;
    }
    if (message == null) {
      // onExit: the isolate is gone.
      _teardown("stopped");
      return;
    }
    if (message is! List || message.isEmpty) return;
    switch (message[0]) {
      case "ready-failed":
        _starting?.completeError(PluginCallException("${message[1]}"));
        _starting = null;
        _teardown("could not load");
      case "host":
        final id = message[1] as int;
        final request = message[2] as String;
        unawaited(_answerHost(id, request));
      case "result":
        final completer = _pending.remove(message[1] as int);
        completer?.complete(message[2]);
      case "error":
        final completer = _pending.remove(message[1] as int);
        completer?.completeError(PluginCallException("${message[2]}"));
      default:
        // onError sends [error, stack] as strings.
        bridge.log.add(PluginLogLevel.error, "Crashed: ${message[0]}");
        _teardown("crashed");
    }
  }

  Future<void> _answerHost(int id, String request) async {
    Map<String, Object?> answer;
    try {
      final decoded = jsonDecode(request);
      answer = decoded is Map<String, Object?>
          ? await bridge.handle(decoded)
          : {"error": "a host request must be a JSON object", "denied": false};
    } on FormatException {
      answer = {"error": "a host request must be JSON", "denied": false};
    }
    _toWorker?.send(["host-reply", id, jsonEncode(answer)]);
  }

  /// Kills the worker and fails whatever was waiting on it.
  void _teardown(String why) {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port?.close();
    _port = null;
    _toWorker = null;
    final starting = _starting;
    _starting = null;
    if (starting != null && !starting.isCompleted) starting.completeError(PluginCallException("the plugin $why"));
    final pending = Map.of(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      completer.completeError(PluginCallException("the plugin $why"));
    }
  }

  void _failed(String why) {
    _failures++;
    bridge.log.add(PluginLogLevel.error, why);
    if (_failures >= maxConsecutiveFailures) {
      suspendedReason = "Suspended after $_failures failures in a row (last: $why)";
      bridge.log.add(PluginLogLevel.error, suspendedReason!);
      _teardown("was suspended");
    }
  }

  @override
  Future<Object?> call(String method, Map<String, Object?> params) async {
    if (_disposed) throw PluginCallException("the plugin was unloaded");
    if (suspendedReason != null) throw PluginCallException(suspendedReason!);
    final request = jsonEncode({"method": method, "params": params});
    if (request.length > maxMessageBytes) throw PluginCallException("request too large");
    try {
      await _start();
    } catch (e) {
      _failed("Could not start: $e");
      throw e is PluginCallException ? e : PluginCallException("$e");
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
    _toWorker!.send(["call", id, request]);
    final Object? raw;
    try {
      raw = await completer.future.timeout(callTimeout);
    } on TimeoutException {
      _pending.remove(id);
      // The worker may be stuck in a loop; only killing it frees it.
      _teardown("timed out");
      _failed("$method timed out after ${callTimeout.inSeconds} s; the plugin was restarted");
      throw PluginCallException("timed out");
    } on PluginCallException catch (e) {
      _failed("$method failed: ${e.message}");
      rethrow;
    }

    final Object? response;
    try {
      response = jsonDecode(raw as String);
    } catch (_) {
      _failed("$method returned something that is not JSON");
      throw PluginCallException("invalid answer");
    }
    if (response is! Map) {
      _failed("$method returned something that is not an object");
      throw PluginCallException("invalid answer");
    }
    if (response["error"] != null) {
      // An error the plugin reported itself is not a crash.
      _failures = 0;
      throw PluginCallException("${response["error"]}");
    }
    _failures = 0;
    return response["result"];
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _teardown("was unloaded");
  }
}

// ---- The worker isolate ---------------------------------------------------------------------------------------------

/// Owns the WebAssembly instance; calls run one at a time because the guest has a single memory and stack.
class _Worker {
  _Worker(this._toHost, this._bytes);

  final SendPort _toHost;
  final Uint8List _bytes;
  final _port = ReceivePort();
  final _hostReplies = <int, Completer<String>>{};
  var _nextHostId = 0;
  Instance? _instance;
  Uint8List? _lastHostAnswer;
  Future<void> _queue = Future.value();

  Future<void> run() async {
    _port.listen(_onMessage);
    try {
      await _instantiate();
    } catch (e) {
      _toHost.send(["ready-failed", "could not load plugin.wasm: $e"]);
      return;
    }
    _toHost.send(_port.sendPort);
  }

  Future<void> _instantiate() async {
    final imports = <String, ModuleImports>{
      "diapason": {
        "host_call": ImportExportKind.function(_hostCall),
        "host_result": ImportExportKind.function(_hostResult),
      },
    };
    _instance = (await WebAssembly.instantiate(_bytes.buffer, imports)).instance;
  }

  Memory get _memory => (_instance!.exports["memory"] as MemoryImportExportValue).ref;

  Uint8List get _bytesView => _memory.buffer.asUint8List();

  Future<Object?> _hostCall(List<Object?> args) async {
    final ptr = (args[0] as num).toInt();
    final len = (args[1] as num).toInt();
    final memory = _bytesView;
    if (ptr < 0 || len < 0 || ptr + len > memory.length || len > WasmRuntime.maxMessageBytes) {
      throw StateError("host_call out of bounds");
    }
    final request = utf8.decode(memory.sublist(ptr, ptr + len), allowMalformed: true);
    final id = _nextHostId++;
    final completer = _hostReplies[id] = Completer<String>();
    _toHost.send(["host", id, request]);
    final answer = utf8.encode(await completer.future);
    _lastHostAnswer = answer;
    return answer.length;
  }

  Object? _hostResult(List<Object?> args) {
    final dst = (args[0] as num).toInt();
    final answer = _lastHostAnswer ?? Uint8List(0);
    final memory = _bytesView;
    if (dst < 0 || dst + answer.length > memory.length) throw StateError("host_result out of bounds");
    memory.setRange(dst, dst + answer.length, answer);
    _lastHostAnswer = null;
    return null;
  }

  void _onMessage(Object? message) {
    if (message is! List) return;
    switch (message[0]) {
      case "host-reply":
        _hostReplies.remove(message[1] as int)?.complete(message[2] as String);
      case "call":
        final id = message[1] as int;
        final request = message[2] as String;
        _queue = _queue.then((_) => _call(id, request));
    }
  }

  /// Exports return a Future when the module imports an async host function, a plain value otherwise.
  static Future<Object?> _invoke(ExportValue? export, List<Object?> args) async {
    if (export is! FunctionImportExportValue) throw StateError("missing export");
    final result = export.ref(args);
    return result is Future ? await result : result;
  }

  Future<void> _call(int id, String request) async {
    try {
      if (_instance == null) await _instantiate();
      final exports = _instance!.exports;
      if (exports["diapason_reset"] != null) await _invoke(exports["diapason_reset"], const []);
      final input = utf8.encode(request);
      final ptr = ((await _invoke(exports["diapason_alloc"], [input.length])) as num).toInt();
      var memory = _bytesView;
      if (ptr <= 0 || ptr + input.length > memory.length) throw StateError("diapason_alloc returned a bad pointer");
      memory.setRange(ptr, ptr + input.length, input);
      final out = ((await _invoke(exports["diapason_handle"], [ptr, input.length])) as num).toInt();
      memory = _bytesView;
      if (memory.length > WasmRuntime.maxMemoryBytes) {
        throw StateError("the plugin uses more than ${WasmRuntime.maxMemoryBytes ~/ (1024 * 1024)} MiB of memory");
      }
      if (out <= 0 || out + 4 > memory.length) throw StateError("diapason_handle returned a bad pointer");
      final length = ByteData.sublistView(memory, out, out + 4).getUint32(0, Endian.little);
      if (length > WasmRuntime.maxMessageBytes || out + 4 + length > memory.length) {
        throw StateError("diapason_handle returned a bad length");
      }
      _toHost.send(["result", id, utf8.decode(memory.sublist(out + 4, out + 4 + length), allowMalformed: true)]);
    } catch (e) {
      // A trap leaves the instance in an unknown state; start the next call from a fresh one.
      _instance = null;
      _toHost.send(["error", id, "$e"]);
    }
  }
}

Future<void> _workerMain((SendPort, TransferableTypedData) args) async {
  final bytes = args.$2.materialize().asUint8List();
  await _Worker(args.$1, bytes).run();
}
