import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

class PcmChunk {
  const PcmChunk(this.samples, this.sampleRate, this.channels);

  final Float32List samples;
  final int sampleRate;
  final int channels;
}

abstract class PcmCaptureBackend {
  Stream<PcmChunk> get chunks;

  Future<bool> start();

  Future<void> stop();
}

class NativeLoopbackPcmCapture implements PcmCaptureBackend {
  static const _methods = MethodChannel("fr.nytuo.diapason/pcm_capture");
  static const _events = EventChannel("fr.nytuo.diapason/pcm_capture_data");

  static final _logger = Logger("NativeLoopbackPcmCapture");

  final _controller = StreamController<PcmChunk>.broadcast();
  StreamSubscription<dynamic>? _subscription;

  @override
  Stream<PcmChunk> get chunks => _controller.stream;

  @override
  Future<bool> start() async {
    Object? result;
    try {
      result = await _methods.invokeMethod("start");
    } on MissingPluginException {
      _logger.info("PCM capture plugin not present on this platform");
      return false;
    } on PlatformException catch (e) {
      _logger.warning("Could not start PCM capture: ${e.message}");
      return false;
    }

    if (result is String) {
      _logger.warning("PCM capture start failed: $result");
      return false;
    }
    if (result != true) return false;

    _subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final pcm = event["pcm"];
        final sampleRate = event["sampleRate"];
        final channels = event["channels"];
        if (pcm is! Float32List || sampleRate is! int || channels is! int || channels < 1) {
          return;
        }
        _controller.add(PcmChunk(pcm, sampleRate, channels));
      },
      onError: (Object e) => _logger.warning("PCM capture stream error: $e"),
    );
    return true;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methods.invokeMethod("stop");
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      _logger.warning("Could not stop PCM capture: ${e.message}");
    }
  }
}
