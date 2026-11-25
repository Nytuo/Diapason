import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Web-safe stand-in for `dart:io`'s [io.Platform].
///
/// On the web, every getter of `dart:io`'s `Platform` throws. Files that branch
/// on the OS import `dart:io` with `hide Platform` and this file instead, so
/// the same `Platform.isAndroid`-style checks simply return false in a
/// browser. Use [isWeb] (or `kIsWeb`) to branch on the web itself.
abstract final class Platform {
  static bool get isWeb => kIsWeb;

  static bool get isAndroid => !kIsWeb && io.Platform.isAndroid;
  static bool get isIOS => !kIsWeb && io.Platform.isIOS;
  static bool get isMacOS => !kIsWeb && io.Platform.isMacOS;
  static bool get isWindows => !kIsWeb && io.Platform.isWindows;
  static bool get isLinux => !kIsWeb && io.Platform.isLinux;
  static bool get isFuchsia => !kIsWeb && io.Platform.isFuchsia;

  /// "web" in a browser, otherwise the `dart:io` value ("android", "ios", ...).
  static String get operatingSystem => kIsWeb ? "web" : io.Platform.operatingSystem;
  static String get operatingSystemVersion => kIsWeb ? "" : io.Platform.operatingSystemVersion;
  static Map<String, String> get environment => kIsWeb ? const {} : io.Platform.environment;
  static String get localHostname => kIsWeb ? "browser" : io.Platform.localHostname;
  static String get lineTerminator => kIsWeb ? "\n" : io.Platform.lineTerminator;
  static String get pathSeparator => kIsWeb ? "/" : io.Platform.pathSeparator;
  static String get version => kIsWeb ? "" : io.Platform.version;
  static String get localeName => kIsWeb ? "en" : io.Platform.localeName;
  static int get numberOfProcessors => kIsWeb ? 1 : io.Platform.numberOfProcessors;
  static String get resolvedExecutable => kIsWeb ? "" : io.Platform.resolvedExecutable;
}
