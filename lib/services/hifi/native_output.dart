import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// The `fr.nytuo.diapason/hifi` channel: CoreAudio on macOS (`macos/Runner/MainFlutterWindow.swift`), the
/// Android 14 bit-perfect mixer on Android (`android/.../HifiChannel.kt`).
class NativeHifiOutput {
  static const _channel = MethodChannel("fr.nytuo.diapason/hifi");
  static final _log = Logger("NativeHifiOutput");

  /// The current output device, as the platform describes it; null when the channel fails.
  static Future<Map<String, dynamic>?> outputDevice() => _call("outputDevice");

  /// macOS: sets the device's nominal rate to [rate] when it supports it, and hog mode when [exclusive].
  static Future<Map<String, dynamic>?> prepareCoreAudio({required int rate, required bool exclusive}) =>
      _call("prepare", {"rate": rate, "exclusive": exclusive});

  /// Android: asks for a bit-perfect mixer at [rate] in [encoding] (`pcm16`, `pcm24`, `pcm32`, `float`) on the USB
  /// DAC. Null when there is none (no USB DAC, Android < 14, or no such mixer).
  static Future<Map<String, dynamic>?> setAndroidBitPerfect({required int rate, required String encoding}) =>
      _call("setBitPerfect", {"rate": rate, "encoding": encoding});

  /// Undoes [prepareCoreAudio] / [setAndroidBitPerfect].
  static Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>("clear");
    } catch (e) {
      _log.fine("clear failed: $e");
    }
  }

  static Future<Map<String, dynamic>?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(method, args);
      return result?.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return null;
    } catch (e, st) {
      _log.warning("$method failed", e, st);
      return null;
    }
  }
}
