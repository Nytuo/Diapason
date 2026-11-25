import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:diapason/services/lyrics/furigana.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
// The package's own entry point embeds the whole dictionary in Dart source (~23 MB). Only its tokenizer is used
// here, fed with the dictionary downloaded on first use, so none of that ends up in the app.
// ignore: implementation_imports
import 'package:kuromoji/src/dict/data/char.dart' show charData;
// ignore: implementation_imports
import 'package:kuromoji/src/dict/dynamic_dictionaries.dart';
// ignore: implementation_imports
import 'package:kuromoji/src/tokenizer.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum JapaneseDictionaryStatus { unsupported, missing, downloading, ready, failed }

@immutable
class JapaneseDictionaryState {
  const JapaneseDictionaryState(this.status, {this.progress = 0, this.error});

  final JapaneseDictionaryStatus status;

  /// 0–1 while downloading.
  final double progress;

  /// User-facing message when [status] is [JapaneseDictionaryStatus.failed].
  final String? error;
}

/// The IPADIC dictionary used to read Japanese lyrics (kuromoji's build of it, ~18 MB), downloaded on demand into the
/// app support directory, and a background isolate that tokenizes lines with it.
///
/// Only the dictionary files are fetched from jsDelivr (pinned to kuromoji 0.1.2 and checked against known hashes);
/// lyrics never leave the device.
class JapaneseDictionary {
  JapaneseDictionary._();

  static final instance = JapaneseDictionary._();

  static final _log = Logger("JapaneseDictionary");

  static const _version = "kuromoji-0.1.2";
  static const _baseUrl = "https://cdn.jsdelivr.net/npm/kuromoji@0.1.2/dict/";

  /// File name → (sha256, size in bytes) of the gzipped dictionary parts.
  static const files = <String, (String, int)>{
    "base.dat.gz": ("0803327762e1c93ca731e4319ab8343340f2806bb84941207782cde9d2d5a8eb", 3956825),
    "cc.dat.gz": ("02b7631be0d4de3a1a75cd9f9cc51536e4f94c9e6b389b813e06ba0f6e7de765", 1692067),
    "check.dat.gz": ("193ae0035fff6fe812b58d9ee730e7a7d7ee601d918481ce51075c58114f6cc9", 3111633),
    "tid.dat.gz": ("d43d831cb6fb0f0a411739cd287a6d5e998e121a8daca614df14a81a0dcac586", 1605820),
    "tid_map.dat.gz": ("33efd5ffd87a70f669add093fa39dee44341d58f940844ef107c8fd98bb795b2", 1485576),
    "tid_pos.dat.gz": ("60dbfc99a6ab993f30c5dab648bec6ad7f9aaefa5c14e1843837d95e509f8895", 5916009),
    "unk.dat.gz": ("f7f991cdeb9bfd3e9c0e4577cc50ee0815a11c508cccd444a9d3ab3c81521100", 10512),
    "unk_char.dat.gz": ("9a8e86fd9aff32d323fbb59f5a7006f05927a11f8173c90712cc56293aeb3225", 306),
    "unk_compat.dat.gz": ("50f60aa29bc2e86c2903ab8c825bb6fa604d2b294d96941c1d3924259791899d", 338),
    "unk_invoke.dat.gz": ("6b210889548457c3006913afd12c8b525562255f2709e404604be9614a25e94c", 1140),
    "unk_map.dat.gz": ("6df12460e5477230bb6fd9641def918b699fc0a8868016b6c9f794488630509b", 1190),
    "unk_pos.dat.gz": ("5b183a29f281acc7e0542beca47b83f7985047c0a2d27e78a66f32276be5ad11", 10540),
  };

  static int get totalBytes => files.values.fold(0, (sum, f) => sum + f.$2);

  final ValueNotifier<JapaneseDictionaryState> state = ValueNotifier(
    const JapaneseDictionaryState(JapaneseDictionaryStatus.missing),
  );

  /// Overrides the storage directory (tests).
  @visibleForTesting
  static String? directoryOverride;

  Future<Directory> _directory() async {
    final base = directoryOverride ?? p.join((await getApplicationSupportDirectory()).path, "japanese_dictionary");
    return Directory(directoryOverride ?? p.join(base, _version));
  }

  bool _checked = false;

  /// Looks at what is on disk; cheap, done once unless [force].
  Future<JapaneseDictionaryState> refresh({bool force = false}) async {
    if (kIsWeb) {
      return state.value = const JapaneseDictionaryState(JapaneseDictionaryStatus.unsupported);
    }
    if (_checked && !force) return state.value;
    if (state.value.status == JapaneseDictionaryStatus.downloading) return state.value;
    _checked = true;
    final dir = await _directory();
    var complete = true;
    for (final entry in files.entries) {
      final file = File(p.join(dir.path, entry.key));
      if (!file.existsSync() || file.lengthSync() != entry.value.$2) {
        complete = false;
        break;
      }
    }
    return state.value = JapaneseDictionaryState(
      complete ? JapaneseDictionaryStatus.ready : JapaneseDictionaryStatus.missing,
    );
  }

  bool get isReady => state.value.status == JapaneseDictionaryStatus.ready;

  Future<void>? _download;

  /// Downloads whatever is missing, reporting progress through [state]. Safe to call twice: the second call joins.
  Future<void> download({http.Client? client}) =>
      _download ??= _doDownload(client).whenComplete(() => _download = null);

  Future<void> _doDownload(http.Client? injected) async {
    final client = injected ?? http.Client();
    final dir = await _directory();
    await dir.create(recursive: true);
    var done = 0;
    state.value = const JapaneseDictionaryState(JapaneseDictionaryStatus.downloading);
    try {
      for (final entry in files.entries) {
        final (hash, size) = entry.value;
        final target = File(p.join(dir.path, entry.key));
        if (target.existsSync() && target.lengthSync() == size) {
          done += size;
          continue;
        }
        final response = await client.send(http.Request("GET", Uri.parse("$_baseUrl${entry.key}")));
        if (response.statusCode != 200) {
          throw HttpException("HTTP ${response.statusCode} for ${entry.key}");
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          bytes.add(chunk);
          state.value = JapaneseDictionaryState(
            JapaneseDictionaryStatus.downloading,
            progress: (done + bytes.length) / totalBytes,
          );
        }
        final data = bytes.takeBytes();
        if (sha256.convert(data).toString() != hash) {
          throw StateError("Checksum mismatch for ${entry.key}");
        }
        final part = File("${target.path}.part");
        await part.writeAsBytes(data, flush: true);
        await part.rename(target.path);
        done += size;
      }
      _checked = true;
      state.value = const JapaneseDictionaryState(JapaneseDictionaryStatus.ready);
      _log.info("Japanese dictionary installed in ${dir.path}");
    } catch (e, stack) {
      _log.warning("Japanese dictionary download failed", e, stack);
      state.value = JapaneseDictionaryState(JapaneseDictionaryStatus.failed, error: "$e");
      rethrow;
    } finally {
      if (injected == null) client.close();
    }
  }

  /// Frees the disk space and stops the tokenizer.
  Future<void> delete() async {
    _worker?.dispose();
    _worker = null;
    final dir = await _directory();
    if (dir.existsSync()) await dir.delete(recursive: true);
    _checked = true;
    state.value = const JapaneseDictionaryState(JapaneseDictionaryStatus.missing);
  }

  /// Megabytes used on disk, for the settings screen.
  static String get sizeLabel => (totalBytes / (1024 * 1024)).toStringAsFixed(0);

  _FuriganaWorker? _worker;

  /// Readings and romaji for each line, worked out in a background isolate. Throws when the dictionary isn't
  /// installed.
  Future<List<FuriganaLine>> annotate(List<String> lines) async {
    await refresh();
    if (!isReady) throw StateError("Japanese dictionary not installed");
    _worker ??= _FuriganaWorker((await _directory()).path);
    return _worker!.annotate(lines);
  }
}

class _FuriganaWorker {
  _FuriganaWorker(this.dictionaryPath);

  final String dictionaryPath;
  Future<SendPort>? _port;
  Isolate? _isolate;
  ReceivePort? _receive;
  final _pending = <int, Completer<List<FuriganaLine>>>{};
  var _nextId = 0;

  Future<SendPort> _start() {
    final ready = Completer<SendPort>();
    final receive = _receive = ReceivePort();
    receive.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final [id as int, result] = message as List<Object?>;
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (result is String) {
        completer.completeError(StateError(result));
      } else {
        completer.complete([
          for (final line in result! as List<Object?>) FuriganaLine.fromWire(line! as List<Object?>),
        ]);
      }
    });
    unawaited(
      Isolate.spawn(_furiganaWorkerMain, [receive.sendPort, dictionaryPath], debugName: "furigana").then(
        (isolate) => _isolate = isolate,
        onError: (Object e) {
          if (!ready.isCompleted) ready.completeError(e);
        },
      ),
    );
    return ready.future;
  }

  Future<List<FuriganaLine>> annotate(List<String> lines) async {
    final port = await (_port ??= _start());
    final id = _nextId++;
    final completer = _pending[id] = Completer();
    port.send([id, lines]);
    return completer.future;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _receive?.close();
    for (final pending in _pending.values) {
      pending.completeError(StateError("Furigana worker stopped"));
    }
    _pending.clear();
  }
}

/// Loads the gzipped dictionary parts from [directory] into a tokenizer.
@visibleForTesting
Tokenizer loadJapaneseTokenizer(String directory) {
  final data = <String, Uint8List>{};
  for (final name in JapaneseDictionary.files.keys) {
    final bytes = gzip.decode(File(p.join(directory, name)).readAsBytesSync());
    // Typed views over these need a buffer of their own that starts at 0.
    data[name.substring(0, name.length - 3)] = Uint8List.fromList(bytes);
  }
  return Tokenizer(DynamicDictionaries(data, charData));
}

/// Tokens of [line], with 、 and 。 kept (the tokenizer drops them).
@visibleForTesting
List<JapaneseToken> tokenizeLine(Tokenizer tokenizer, String line) {
  final tokens = <JapaneseToken>[];
  final chunk = StringBuffer();
  void flush() {
    if (chunk.isEmpty) return;
    for (final t in tokenizer.tokenize(chunk.toString())) {
      tokens.add(
        JapaneseToken(surface: t["surface_form"] as String, reading: t["reading"] as String?, pos: t["pos"] as String?),
      );
    }
    chunk.clear();
  }

  for (final rune in line.runes) {
    final char = String.fromCharCode(rune);
    if (char == "、" || char == "。") {
      flush();
      tokens.add(JapaneseToken(surface: char));
    } else {
      chunk.write(char);
    }
  }
  flush();
  return tokens;
}

/// Readings over the kanji of [line] and its romaji; empty for lines without Japanese.
@visibleForTesting
FuriganaLine annotateLine(Tokenizer tokenizer, String line) {
  if (!Furigana.hasJapanese(line)) return FuriganaLine.empty;
  final tokens = tokenizeLine(tokenizer, line);
  return FuriganaLine(ruby: Furigana.rubyForTokens(line, tokens) ?? const [], romaji: Furigana.romajiForTokens(tokens));
}

void _furiganaWorkerMain(List<Object?> args) {
  final reply = args[0]! as SendPort;
  final directory = args[1]! as String;
  final requests = ReceivePort();
  reply.send(requests.sendPort);
  Tokenizer? tokenizer;
  requests.listen((message) {
    final [id as int, lines as List<Object?>] = message as List<Object?>;
    try {
      tokenizer ??= loadJapaneseTokenizer(directory);
      reply.send([
        id,
        [for (final line in lines) annotateLine(tokenizer!, line! as String).toWire()],
      ]);
    } catch (e) {
      reply.send([id, "$e"]);
    }
  });
}
