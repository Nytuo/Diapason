import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/hifi/dsd/dsd_container.dart';

/// DoP (DSD over PCM, v1.1): the DSD bits carried untouched inside 24-bit PCM, sixteen DSD samples per PCM frame
/// and channel, the top byte a marker (0x05, 0xFA, alternating) that a DoP DAC recognises to switch to DSD.
///
/// A DoP stream is only DSD if every bit reaches the DAC unchanged: no volume, no resampling, no dither, no mixing.
/// Anything less and the DAC plays it as PCM: loud noise. So it is only offered where the output is bit-perfect
/// (mpv on an exclusive or `hw:` device with every filter off).

const int dopMarkerA = 0x05;
const int dopMarkerB = 0xFA;

/// PCM rate that carries [dsdRate] as DoP (176.4 kHz for DSD64).
int dopRateFor(int dsdRate) => dsdRate ~/ 16;

/// Turns a stereo [DsdSource] into DoP frames (24-bit little endian, interleaved).
class DopEncoder {
  DopEncoder(this.source) {
    if (source.channels != 2) throw DsdFormatException("DoP is offered for stereo only (${source.channels} channels)");
    totalFrames = source.samples ~/ 16;
  }

  final DsdSource source;
  late final int totalFrames;
  int _frame = 0;
  int _discardBytes = 0;
  Uint8List _carryLeft = Uint8List(0);
  Uint8List _carryRight = Uint8List(0);

  int get sampleRate => dopRateFor(source.sampleRate);
  int get channels => 2;

  void seekToFrame(int frame) {
    frame = min(frame, totalFrames);
    final landed = source.seek(frame * 16);
    // The container may land earlier (DSF blocks): drop the bytes before the frame.
    _discardBytes = frame * 2 - landed ~/ 8;
    _frame = frame;
    _carryLeft = Uint8List(0);
    _carryRight = Uint8List(0);
  }

  /// The next DoP frames as 24-bit LE bytes, or `null` at the end.
  Uint8List? nextBytes() {
    while (true) {
      if (_frame >= totalFrames) return null;
      final block = source.nextBlock();
      if (block == null) return null;
      var left = _join(_carryLeft, block[0]);
      var right = _join(_carryRight, block[1]);
      if (_discardBytes > 0) {
        final d = min(_discardBytes, min(left.length, right.length));
        left = Uint8List.sublistView(left, d);
        right = Uint8List.sublistView(right, d);
        _discardBytes -= d;
      }
      final pairs = min(min(left.length, right.length) ~/ 2, totalFrames - _frame);
      _carryLeft = Uint8List.fromList(Uint8List.sublistView(left, pairs * 2));
      _carryRight = Uint8List.fromList(Uint8List.sublistView(right, pairs * 2));
      if (pairs == 0) continue;
      final out = Uint8List(pairs * 6);
      encodeDop(left, right, pairs, _frame, out);
      _frame += pairs;
      return out;
    }
  }

  static Uint8List _join(Uint8List a, Uint8List b) {
    if (a.isEmpty) return b;
    return Uint8List(a.length + b.length)
      ..setAll(0, a)
      ..setAll(a.length, b);
  }
}

/// Packs [frames] DoP frames from MSB-first DSD bytes; the marker follows the absolute frame number, so it keeps
/// alternating across seeks.
void encodeDop(Uint8List left, Uint8List right, int frames, int firstFrame, Uint8List out) {
  var k = 0;
  for (var i = 0; i < frames; i++) {
    final marker = (firstFrame + i).isEven ? dopMarkerA : dopMarkerB;
    // 24-bit little endian: low byte (the later DSD byte), middle (the earlier), high (the marker).
    out[k++] = left[2 * i + 1];
    out[k++] = left[2 * i];
    out[k++] = marker;
    out[k++] = right[2 * i + 1];
    out[k++] = right[2 * i];
    out[k++] = marker;
  }
}
