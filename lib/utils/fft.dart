import 'dart:math';
import 'dart:typed_data';

class RealFft {
  RealFft(this.size)
    : assert(size > 1 && (size & (size - 1)) == 0, "size must be a power of two"),
      _re = Float64List(size),
      _im = Float64List(size),
      _hann = Float64List(size),
      _bitReversal = Int32List(size),
      _cos = Float64List(size ~/ 2),
      _sin = Float64List(size ~/ 2) {
    final bits = _log2(size);
    for (var i = 0; i < size; i++) {
      var x = i;
      var r = 0;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      _bitReversal[i] = r;
    }
    for (var i = 0; i < size ~/ 2; i++) {
      final angle = -2 * pi * i / size;
      _cos[i] = cos(angle);
      _sin[i] = sin(angle);
    }
    for (var i = 0; i < size; i++) {
      _hann[i] = 0.5 - 0.5 * cos(2 * pi * i / size);
    }
  }

  final int size;

  final Float64List _re;
  final Float64List _im;
  final Float64List _hann;
  final Int32List _bitReversal;
  final Float64List _cos;
  final Float64List _sin;

  double get _normalisation => 4.0 / size;

  static int _log2(int n) {
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    return bits;
  }

  Float32List magnitudes(Float32List samples, Float32List out) {
    assert(samples.length == size);
    assert(out.length == size ~/ 2);

    for (var i = 0; i < size; i++) {
      final j = _bitReversal[i];
      _re[i] = samples[j] * _hann[j];
      _im[i] = 0.0;
    }

    for (var len = 2; len <= size; len <<= 1) {
      final half = len >> 1;
      final stride = size ~/ len;
      for (var start = 0; start < size; start += len) {
        var k = 0;
        for (var i = start; i < start + half; i++) {
          final wr = _cos[k];
          final wi = _sin[k];
          final tr = wr * _re[i + half] - wi * _im[i + half];
          final ti = wr * _im[i + half] + wi * _re[i + half];
          _re[i + half] = _re[i] - tr;
          _im[i + half] = _im[i] - ti;
          _re[i] += tr;
          _im[i] += ti;
          k += stride;
        }
      }
    }

    final norm = _normalisation;
    final bins = size ~/ 2;
    for (var i = 0; i < bins; i++) {
      final m = sqrt(_re[i] * _re[i] + _im[i] * _im[i]) * norm;
      out[i] = m > 1.0 ? 1.0 : m;
    }
    return out;
  }
}
