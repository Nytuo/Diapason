import 'dart:math';
import 'dart:typed_data';

import 'package:diapason/services/hifi/dsd/dsd_container.dart';

/// Streaming DSD to PCM conversion, for the players that cannot decode DSD themselves (AVFoundation, ExoPlayer).
///
/// A first FIR stage turns each DSD byte into one PCM sample (eight to one); a chain of half-band filters then brings
/// every DSD rate down to 88.2 kHz. The first stage is a port of Sebastian Gesemann's `dsd2pcm` (BSD-2-Clause, see
/// `licenses` in Chilpa's `chilpa-audio` crate, from which this port is taken); the coefficient table and the
/// byte-folding trick are upstream's.
///
/// This is a conversion: the result is not bit-perfect DSD, and the signal path says so.

/// PCM rate of converted DSD.
const int dsdPcmOutputRate = 88200;

/// Headroom: low-passed DSD can exceed PCM full scale (SACD allows +3 dB over 0 dBFS PCM).
const double dsdPcmGainDb = -6.0;

const int _halfTaps = 48;
const int _fifoSize = 16;
const int _fifoMask = _fifoSize - 1;
const int _tables = 6;

const List<double> _taps = [
  0.09950731974056658, 0.09562845727714668, 0.08819647126516944, //
  0.07782552527068175, 0.06534876523171299, 0.05172629311427257,
  0.0379429484910187, 0.02490921351762261, 0.0133774746265897,
  0.003883043418804416, -0.003284703416210726, -0.008080250212687497,
  -0.01067241812471033, -0.01139427235000863, -0.0106813877974587,
  -0.009007905078766049, -0.006828859761015335, -0.004535184322001496,
  -0.002425035959059578, -0.0006922187080790708, 0.0005700762132016592,
  0.001353838005269448, 0.001713709690937, 0.001742046839472948,
  0.001545601648013235, 0.001226696225277855, 0.0008704322683580222,
  0.0005381636200535649, 0.000266446345425276, 0.00007002968740383528,
  -0.000052794070532407, -0.0001140625650874684, -0.0001304796361231895,
  -0.0001189970287491285, -0.0000939624715507305, -0.000065776341883272,
  -0.0000407492895835035, -0.0000217407957554587, -0.00000916305893159272,
  -0.0000020174601450322016, 0.000001249721855219005,
  0.0000021666551905373926, 0.0000019305208929910826,
  0.000001319400334374195, 0.0000007410039764049091,
  0.0000003423230509967409, 0.0000001244182214744588,
  0.00000003130441005359396,
];

final Uint8List _reverse = Uint8List.fromList(
  List.generate(256, (b) {
    var r = 0;
    for (var i = 0; i < 8; i++) {
      if (b & (1 << i) != 0) r |= 0x80 >> i;
    }
    return r;
  }),
);

/// `_sums[t * 256 + byte]`: the contribution of one byte to the FIR output, per table.
final Float32List _sums = () {
  final sums = Float32List(_tables * 256);
  for (var table = 0; table < _tables; table++) {
    final count = min(_halfTaps - table * 8, 8);
    for (var byte = 0; byte < 256; byte++) {
      var sum = 0.0;
      for (var bit = 0; bit < count; bit++) {
        final sign = ((byte >> (7 - bit)) & 1) * 2 - 1;
        sum += sign * _taps[table * 8 + bit];
      }
      sums[(_tables - 1 - table) * 256 + byte] = sum;
    }
  }
  return sums;
}();

/// One channel of DSD (MSB first), decimated eight to one.
class Dsd2PcmStage {
  // A DC-balanced DSD idle pattern: no transient while the history fills.
  final Uint8List _fifo = Uint8List(_fifoSize)..fillRange(0, _fifoSize, 0x69);
  int _position = 0;

  Float32List translate(Uint8List source) {
    final out = Float32List(source.length);
    final fifo = _fifo;
    final sums = _sums;
    var position = _position;
    for (var i = 0; i < source.length; i++) {
      fifo[position] = source[i];
      final mirrored = (position - _tables) & _fifoMask;
      fifo[mirrored] = _reverse[fifo[mirrored]];
      var sum = 0.0;
      for (var table = 0; table < _tables; table++) {
        final front = fifo[(position - table) & _fifoMask];
        final back = fifo[(position - (_tables * 2 - 1) + table) & _fifoMask];
        sum += sums[table * 256 + front] + sums[table * 256 + back];
      }
      out[i] = sum;
      position = (position + 1) & _fifoMask;
    }
    _position = position;
    return out;
  }
}

const int _halfBandTaps = 63;

final Float32List _halfBand = () {
  final taps = Float64List(_halfBandTaps);
  const center = (_halfBandTaps - 1) / 2.0;
  var total = 0.0;
  for (var i = 0; i < _halfBandTaps; i++) {
    final x = i - center;
    final sinc = x == 0 ? 0.5 : sin(pi * 0.5 * x) / (pi * x);
    final window = 0.42 - 0.5 * cos(2 * pi * i / (_halfBandTaps - 1)) + 0.08 * cos(4 * pi * i / (_halfBandTaps - 1));
    taps[i] = sinc * window;
    total += taps[i];
  }
  return Float32List.fromList([for (final t in taps) t / total]);
}();

/// Streaming half-band low-pass, two to one.
class HalfBandStage {
  Float32List _history = Float32List(_halfBandTaps - 1);
  int _next = _halfBandTaps - 1;

  Float32List process(Float32List input) {
    final pending = Float32List(_history.length + input.length)
      ..setAll(0, _history)
      ..setAll(_history.length, input);
    final taps = _halfBand;
    final out = Float32List(max(0, (pending.length - _next + 1) ~/ 2));
    var n = 0;
    var center = _next;
    while (center < pending.length) {
      final base = center + 1 - _halfBandTaps;
      var sum = 0.0;
      for (var tap = 0; tap < _halfBandTaps; tap += 2) {
        sum += taps[tap] * pending[base + _halfBandTaps - 1 - tap];
      }
      sum += taps[_halfBandTaps ~/ 2] * pending[base + _halfBandTaps ~/ 2];
      out[n++] = sum;
      center += 2;
    }
    final keepFrom = max(0, pending.length - (_halfBandTaps - 1));
    final overshoot = center - pending.length;
    _history = Float32List.fromList(Float32List.sublistView(pending, keepFrom));
    _next = _halfBandTaps - 1 + overshoot;
    return n == out.length ? out : Float32List.sublistView(out, 0, n);
  }
}

/// Planar DSD to planar PCM at [dsdPcmOutputRate], keeping every filter's history across calls.
class DsdDecimator {
  DsdDecimator._(this._first, this._halfBands);

  /// `null` when [dsdRate] cannot be brought to 88.2 kHz by these stages.
  static DsdDecimator? create(int dsdRate, int channels) {
    if (channels < 1 || dsdRate % dsdPcmOutputRate != 0) return null;
    final ratio = dsdRate ~/ dsdPcmOutputRate;
    final afterFirst = ratio ~/ 8;
    if (ratio < 16 || afterFirst & (afterFirst - 1) != 0) return null;
    final stages = afterFirst.bitLength - 1;
    return DsdDecimator._(
      List.generate(channels, (_) => Dsd2PcmStage()),
      List.generate(stages, (_) => List.generate(channels, (_) => HalfBandStage())),
    );
  }

  final List<Dsd2PcmStage> _first;
  final List<List<HalfBandStage>> _halfBands;

  List<Float32List> process(List<Uint8List> planar) {
    final out = <Float32List>[];
    for (var c = 0; c < planar.length; c++) {
      var samples = _first[c].translate(planar[c]);
      for (final stage in _halfBands) {
        samples = stage[c].process(samples);
      }
      out.add(samples);
    }
    return out;
  }
}

/// Converts a [DsdSource] to interleaved stereo float PCM at 88.2 kHz, with seeking.
class DsdPcmConverter {
  DsdPcmConverter(this.source, {double gainDb = dsdPcmGainDb})
    : _gain = pow(10, gainDb / 20).toDouble(),
      ratio = source.sampleRate ~/ dsdPcmOutputRate {
    final decimator = DsdDecimator.create(source.sampleRate, source.channels);
    if (decimator == null) throw DsdFormatException("${source.sampleRate} Hz cannot be converted to 88.2 kHz");
    _decimator = decimator;
    totalFrames = source.samples ~/ ratio;
  }

  final DsdSource source;
  final double _gain;

  /// DSD samples per PCM frame.
  final int ratio;
  late DsdDecimator _decimator;
  late final int totalFrames;
  int _emitted = 0;
  bool _finished = false;
  int _discardBytes = 0;
  int _discardFrames = 0;

  int get channels => 2;
  int get sampleRate => dsdPcmOutputRate;

  /// Moves to PCM [frame], warming the filters on 128 frames of history before it.
  void seekToFrame(int frame) {
    frame = min(frame, totalFrames);
    final start = max(0, frame - 128) * ratio;
    final landed = source.seek(start);
    // Container alignment (DSF blocks) can land before the history: keep the absolute PCM frame grid.
    final aligned = (landed + ratio - 1) ~/ ratio * ratio;
    _discardBytes = (aligned - landed) ~/ 8;
    _emitted = min(aligned ~/ ratio, totalFrames);
    final target = max(frame, _emitted);
    _discardFrames = target - _emitted;
    _decimator = DsdDecimator.create(source.sampleRate, source.channels)!;
    _finished = false;
  }

  /// The next block of interleaved stereo samples, or `null` at the end.
  Float32List? nextBlock() {
    while (true) {
      final block = _convertBlock();
      if (block == null) return null;
      final frames = block.length ~/ 2;
      final discard = min(_discardFrames, frames);
      _discardFrames -= discard;
      if (discard == frames) continue;
      return discard == 0 ? block : Float32List.sublistView(block, discard * 2);
    }
  }

  Float32List? _convertBlock() {
    while (true) {
      if (_finished) return null;
      var planar = source.nextBlock();
      if (planar == null) {
        _finished = true;
        final missing = totalFrames - _emitted;
        _emitted = totalFrames;
        return missing > 0 ? Float32List(missing * 2) : null;
      }
      if (_discardBytes > 0) {
        final shortest = planar.map((c) => c.length).reduce(min);
        final discard = min(_discardBytes, shortest);
        planar = [for (final c in planar) Uint8List.sublistView(c, discard)];
        _discardBytes -= discard;
      }
      final pcm = _decimator.process(planar);
      final available = pcm.map((c) => c.length).reduce(min);
      final frames = min(available, totalFrames - _emitted);
      if (frames <= 0) {
        if (_emitted >= totalFrames) _finished = true;
        continue;
      }
      final out = Float32List(frames * 2);
      _downmix(pcm, frames, out);
      _emitted += frames;
      if (_emitted >= totalFrames) _finished = true;
      return out;
    }
  }

  void _downmix(List<Float32List> ch, int frames, Float32List out) {
    final g = _gain;
    switch (ch.length) {
      case 1:
        for (var i = 0; i < frames; i++) {
          out[2 * i] = out[2 * i + 1] = ch[0][i] * g;
        }
      case 2:
        for (var i = 0; i < frames; i++) {
          out[2 * i] = ch[0][i] * g;
          out[2 * i + 1] = ch[1][i] * g;
        }
      default:
        // Multichannel: fold the centre and the surrounds in at -3 dB, then normalise.
        const minus3 = 0.7071067811865476;
        final n = ch.length;
        final center = (n == 3 || n == 5 || n == 6) ? 2 : null;
        final (sl, sr) = switch (n) {
          4 => (2, 3),
          5 => (3, 4),
          6 => (4, 5),
          _ => (null, null),
        };
        final norm = 1.0 / (1.0 + (center != null ? minus3 : 0) + (sl != null ? minus3 : 0));
        for (var i = 0; i < frames; i++) {
          var l = ch[0][i];
          var r = ch[1][i];
          if (center != null) {
            l += minus3 * ch[center][i];
            r += minus3 * ch[center][i];
          }
          if (sl != null) l += minus3 * ch[sl][i];
          if (sr != null) r += minus3 * ch[sr][i];
          out[2 * i] = l * norm * g;
          out[2 * i + 1] = r * norm * g;
        }
    }
  }
}

/// Bytes of a 24-bit stereo WAV frame.
const int wavFrameBytes = 6;
const int wavHeaderBytes = 44;

/// A canonical 44-byte header for 24-bit stereo PCM WAV with [frames] frames.
Uint8List wavHeader({required int frames, int sampleRate = dsdPcmOutputRate, int channels = 2, int bits = 24}) {
  final blockAlign = channels * bits ~/ 8;
  final dataBytes = frames * blockAlign;
  final b = ByteData(wavHeaderBytes);
  void id(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  id(0, "RIFF");
  b.setUint32(4, 36 + dataBytes, Endian.little);
  id(8, "WAVE");
  id(12, "fmt ");
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * blockAlign, Endian.little);
  b.setUint16(32, blockAlign, Endian.little);
  b.setUint16(34, bits, Endian.little);
  id(36, "data");
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

/// Float samples to little-endian signed 24-bit, clipped.
Uint8List floatTo24BitLE(Float32List samples) {
  final out = Uint8List(samples.length * 3);
  for (var i = 0, k = 0; i < samples.length; i++) {
    var v = (samples[i] * 8388607.0).round();
    if (v > 8388607) v = 8388607;
    if (v < -8388608) v = -8388608;
    out[k++] = v & 0xff;
    out[k++] = (v >> 8) & 0xff;
    out[k++] = (v >> 16) & 0xff;
  }
  return out;
}
