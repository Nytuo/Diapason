/// Web build of [DiscordRpc]: Discord Rich Presence talks to the local Discord
/// client over IPC through a Rust FFI plugin, which a browser can't do. The
/// setting is hidden on the web (see `PlaybackReportingSettingsScreen`), and
/// these calls do nothing.
class DiscordRpc {
  static Future<void> initialize() async {}

  static Future<void> start() async {}

  static Future<void> stop({bool force = false}) async {}

  static Future<void> updateRPC() async {}
}
