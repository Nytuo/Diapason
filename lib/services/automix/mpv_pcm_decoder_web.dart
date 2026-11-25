import 'dart:typed_data';

/// Web build of `MpvPcmDecoder`: libmpv is loaded through `dart:ffi`, which
/// doesn't exist in a browser, so automix beat analysis has no decoder there.
class MpvPcmDecoder {
  static bool get available => false;

  static Float32List? decode({
    required String source,
    Map<String, String> headers = const {},
    required Duration start,
    required Duration length,
    required int sampleRate,
    required String scratchPath,
  }) => null;
}
