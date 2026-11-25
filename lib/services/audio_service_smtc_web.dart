/// Web build of `AudioServiceSMTC`: the Windows System Media Transport
/// Controls plugin is native-only (Rust FFI). `main.dart` only registers it on
/// Windows, so on the web this is never called.
class AudioServiceSMTC {
  static void registerWith() {
    throw UnsupportedError("SMTC is only available on Windows");
  }
}
