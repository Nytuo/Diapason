import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/hifi/dsd/dop.dart';
import 'package:diapason/services/hifi/dsd/dsd_container.dart';
import 'package:diapason/services/hifi/dsd/dsd_to_pcm.dart';

/// 24-bit PCM produced on demand from DSD: either converted ([DsdPcmConverter]) or DoP-packed ([DopEncoder]).
abstract class WavProducer {
  DsdSource get source;
  int get sampleRate;
  int get channels;
  int get totalFrames;
  void seekToFrame(int frame);

  /// Interleaved 24-bit little-endian frames, or `null` at the end.
  Uint8List? nextBytes();

  int get frameBytes => channels * 3;
  int get byteLength => wavHeaderBytes + totalFrames * frameBytes;
}

class PcmWavProducer extends WavProducer {
  PcmWavProducer(DsdSource source) : converter = DsdPcmConverter(source);

  final DsdPcmConverter converter;

  @override
  DsdSource get source => converter.source;
  @override
  int get sampleRate => converter.sampleRate;
  @override
  int get channels => converter.channels;
  @override
  int get totalFrames => converter.totalFrames;
  @override
  void seekToFrame(int frame) => converter.seekToFrame(frame);
  @override
  Uint8List? nextBytes() {
    final block = converter.nextBlock();
    return block == null ? null : floatTo24BitLE(block);
  }
}

class DopWavProducer extends WavProducer {
  DopWavProducer(DsdSource source) : encoder = DopEncoder(source);

  final DopEncoder encoder;

  @override
  DsdSource get source => encoder.source;
  @override
  int get sampleRate => encoder.sampleRate;
  @override
  int get channels => encoder.channels;
  @override
  int get totalFrames => encoder.totalFrames;
  @override
  void seekToFrame(int frame) => encoder.seekToFrame(frame);
  @override
  Uint8List? nextBytes() => encoder.nextBytes();
}

/// The bytes [start, end) of the virtual WAV file made from [producer], produced on demand.
///
/// Byte offsets map linearly to frames, so a range request (a seek) only produces from just before that point.
/// [waitFor], when given, is awaited with the file offset the next read needs (a download still in progress).
Stream<List<int>> virtualWavRange(
  WavProducer producer,
  int start,
  int end, {
  Future<void> Function(int offset)? waitFor,
}) async* {
  final header = wavHeader(frames: producer.totalFrames, sampleRate: producer.sampleRate, channels: producer.channels);
  end = min(end, producer.byteLength);
  var position = start;
  if (position < wavHeaderBytes) {
    final h = Uint8List.sublistView(header, position, min(wavHeaderBytes, end));
    yield h;
    position += h.length;
  }
  if (position >= end) return;
  final frameBytes = producer.frameBytes;
  final firstFrame = (position - wavHeaderBytes) ~/ frameBytes;
  var skip = (position - wavHeaderBytes) - firstFrame * frameBytes;
  if (waitFor != null) await waitFor(producer.source.nextReadEnd);
  producer.seekToFrame(firstFrame);
  while (position < end) {
    if (waitFor != null) await waitFor(producer.source.nextReadEnd);
    var bytes = producer.nextBytes();
    if (bytes == null) break;
    if (skip > 0) {
      bytes = Uint8List.sublistView(bytes, min(skip, bytes.length));
      skip = 0;
    }
    if (bytes.length > end - position) bytes = Uint8List.sublistView(bytes, 0, end - position);
    position += bytes.length;
    yield bytes;
    // Let the event loop breathe between blocks: this runs on the isolate that hosts the player.
    await Future<void>.delayed(Duration.zero);
  }
  // A source that ends early (a truncated file): pad with silence so the declared length holds.
  if (position < end) {
    final silence = Uint8List(min(end - position, 1 << 20));
    while (position < end) {
      final n = min(silence.length, end - position);
      yield Uint8List.sublistView(silence, 0, n);
      position += n;
    }
  }
}
