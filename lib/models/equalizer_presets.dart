import 'dart:math';

/// The standard 10-band ISO center frequencies (Hz) that equalizer presets
/// are defined against. This matches `darwinEqualizerCenterFrequencies` in
/// the just_audio fork exactly, since iOS/macOS always use this fixed band
/// layout. Android devices report their own band layout (usually 5 bands),
/// so presets are mapped onto whatever bands the device actually has via
/// [equalizerPresetGainForFrequency].
const List<double> equalizerIsoCenterFrequencies = [
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

/// Preset name -> gain in decibels per band, indexed the same as
/// [equalizerIsoCenterFrequencies].
const Map<String, List<double>> equalizerPresets = {
  "Flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  "Bass Boost": [6, 6, 5, 3, 1, 0, 0, 0, 0, 0],
  "Treble Boost": [0, 0, 0, 0, 0, 1, 3, 5, 6, 6],
  "Vocal": [-2, -2, -1, 2, 4, 4, 3, 1, -1, -2],
  "Rock": [4, 3, 2, 0, -2, -1, 1, 3, 4, 4],
  "Pop": [-1, 1, 3, 3, 1, -1, -1, 1, 2, 2],
  "Jazz": [3, 2, 1, 2, -1, -1, 0, 1, 2, 3],
  "Classical": [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],
  "Electronic": [5, 4, 1, 0, -2, 1, 0, 1, 4, 5],
  "Acoustic": [3, 3, 1, 1, 0, 1, 2, 3, 3, 2],
  "Loudness": [5, 4, 2, 0, -1, -1, 0, 2, 4, 5],
};

/// The gain [presetName] assigns at [frequencyHz], found by matching to the
/// nearest of [equalizerIsoCenterFrequencies] on a logarithmic scale (pitch,
/// and this preset table's own band spacing, are perceived logarithmically).
/// Used so a preset defined for the fixed 10-band iOS layout can still be
/// applied to a device-reported Android band layout of a different size.
double equalizerPresetGainForFrequency(String presetName, double frequencyHz) {
  final gains = equalizerPresets[presetName];
  if (gains == null || frequencyHz <= 0) return 0.0;

  var nearestIndex = 0;
  var nearestDistance = double.infinity;
  for (var i = 0; i < equalizerIsoCenterFrequencies.length; i++) {
    final distance = (log(frequencyHz) - log(equalizerIsoCenterFrequencies[i])).abs();
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestIndex = i;
    }
  }
  return gains[nearestIndex];
}
