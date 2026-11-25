import 'package:diapason/utils/platform.dart';

/// What drives the output on this platform, and so what bit-perfect can mean here.
enum HifiBackend {
  /// Linux, Windows: libmpv (just_audio_media_kit). Exclusive mode, device choice, no filters.
  mpv,

  /// macOS: AVFoundation on CoreAudio. Device rate matching and hog mode; the system mixer stays in the path.
  coreAudio,

  /// Android 14+: the framework's bit-perfect mixer on USB DACs.
  androidMixer,

  /// iOS, iPadOS, tvOS: AVAudioSession decides the rate and mixes; no bit-perfect output is possible.
  none,
}

HifiBackend get currentHifiBackend {
  if (Platform.isLinux || Platform.isWindows) return HifiBackend.mpv;
  if (Platform.isMacOS) return HifiBackend.coreAudio;
  if (Platform.isAndroid) return HifiBackend.androidMixer;
  return HifiBackend.none;
}
