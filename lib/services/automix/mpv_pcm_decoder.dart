import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Decodes a window of a track with the libmpv that media_kit already ships on Windows and Linux, writing it as a
/// mono 16-bit WAV (mpv's `pcm` audio output), then reads it back. Blocking: run it in an isolate.
class MpvPcmDecoder {
  static const _libraries = {
    "windows": ["libmpv-2.dll", "mpv-2.dll", "mpv-1.dll"],
    "linux": ["libmpv.so.2", "libmpv.so", "libmpv.so.1"],
  };

  static DynamicLibrary? _open() {
    for (final name in _libraries[Platform.operatingSystem] ?? const <String>[]) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    return null;
  }

  static bool get available => _open() != null;

  static const _eventShutdown = 1;
  static const _eventEndFile = 7;

  /// [source] is a file path or an http(s) URL. Null when libmpv is missing or decoding failed.
  static Float32List? decode({
    required String source,
    Map<String, String> headers = const {},
    required Duration start,
    required Duration length,
    required int sampleRate,
    required String scratchPath,
  }) {
    final lib = _open();
    if (lib == null) return null;

    final create = lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>("mpv_create");
    final setOption = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
        >("mpv_set_option_string");
    final initialize = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>("mpv_initialize");
    final command = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
          int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)
        >("mpv_command");
    final waitEvent = lib
        .lookupFunction<Pointer<Int32> Function(Pointer<Void>, Double), Pointer<Int32> Function(Pointer<Void>, double)>(
          "mpv_wait_event",
        );
    final destroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      "mpv_terminate_destroy",
    );

    final out = File(scratchPath);
    if (out.existsSync()) out.deleteSync();

    final handle = create();
    if (handle == nullptr) return null;
    final allocated = <Pointer<Utf8>>[];
    Pointer<Utf8> str(String s) {
      final p = s.toNativeUtf8();
      allocated.add(p);
      return p;
    }

    try {
      final options = {
        "config": "no",
        "terminal": "no",
        "idle": "no",
        "load-scripts": "no",
        "ytdl": "no",
        "vid": "no",
        "vo": "null",
        "sub": "no",
        "audio-display": "no",
        "ao": "pcm",
        "ao-pcm-file": scratchPath,
        "ao-pcm-waveheader": "yes",
        "untimed": "yes",
        "audio-format": "s16",
        "audio-samplerate": "$sampleRate",
        "audio-channels": "mono",
        "start": (start.inMilliseconds / 1000).toStringAsFixed(3),
        "length": (length.inMilliseconds / 1000).toStringAsFixed(3),
        if (headers.isNotEmpty)
          "http-header-fields": headers.entries.map((e) => "${e.key}: ${e.value.replaceAll(",", r"\,")}").join(","),
      };
      for (final option in options.entries) {
        setOption(handle, str(option.key), str(option.value));
      }
      if (initialize(handle) < 0) return null;

      final args = calloc<Pointer<Utf8>>(3);
      try {
        args[0] = str("loadfile");
        args[1] = str(source);
        args[2] = nullptr;
        if (command(handle, args) < 0) return null;
      } finally {
        calloc.free(args);
      }

      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        final event = waitEvent(handle, 1.0);
        final id = event.value;
        if (id == _eventEndFile || id == _eventShutdown) break;
      }
    } finally {
      destroy(handle); // also finishes the WAV header
      for (final p in allocated) {
        calloc.free(p);
      }
    }

    if (!out.existsSync()) return null;
    try {
      return readWav16(out.readAsBytesSync());
    } finally {
      try {
        out.deleteSync();
      } catch (_) {}
    }
  }

  /// Mono 16-bit little-endian WAV to floats. Copes with a header whose sizes were never filled in.
  static Float32List? readWav16(Uint8List bytes) {
    if (bytes.length < 44) return null;
    final data = ByteData.sublistView(bytes);
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      var size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == "data") {
        if (size == 0 || size == 0xFFFFFFFF || body + size > bytes.length) size = bytes.length - body;
        final count = size ~/ 2;
        final out = Float32List(count);
        for (var i = 0; i < count; i++) {
          out[i] = data.getInt16(body + i * 2, Endian.little) / 32768.0;
        }
        return out;
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }
}
