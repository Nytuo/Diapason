import 'package:shared_preferences/shared_preferences.dart';

/// Persisted preferences for the in-app updater.
///
/// Diapason's Android and desktop builds aren't distributed through the stores,
/// so those users are offered updates straight from GitHub releases. This toggle
/// controls whether the app checks for a newer build on launch. It lives in
/// shared_preferences on purpose so it stays independent of the Hive-backed
/// [FinampSettings] model.
class UpdaterPrefs {
  const UpdaterPrefs._();

  static const _autoCheckKey = "updater_auto_check";
  // Legacy key from when this was Android-only; read for backwards compat.
  static const _legacyAndroidKey = "android_updater_auto_check";

  /// Whether to check GitHub for a newer build on launch. Defaults to `true`.
  static Future<bool> isAutoCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoCheckKey) ?? prefs.getBool(_legacyAndroidKey) ?? true;
  }

  static Future<void> setAutoCheckEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoCheckKey, value);
  }
}
