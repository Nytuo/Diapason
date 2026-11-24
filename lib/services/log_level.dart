import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// The user-selectable detail of the in-app log.
enum LogDetail {
  auto("auto", "Auto", "Everything in debug builds, errors only in release builds (fastest).", null),
  errors("errors", "Errors", "Only errors, including those shown to you as a message. Fastest.", Level.SEVERE),
  warning("warning", "Warnings", "Only warnings and errors.", Level.WARNING),
  info("info", "Info", "Notable events and problems.", Level.INFO),
  all("all", "All", "Most detail. Best for bug reports; the log file grows faster.", Level.ALL);

  const LogDetail(this.id, this.label, this.description, this.level);

  final String id;
  final String label;
  final String description;
  final Level? level;

  /// The level that applies right now ([auto] depends on the build).
  Level get effectiveLevel => level ?? (kDebugMode ? Level.ALL : Level.SEVERE);

  static LogDetail fromId(String id) => values.firstWhere((d) => d.id == id, orElse: () => LogDetail.auto);
}

/// Applies the saved log detail to the root logger.
void applyConfiguredLogLevel() {
  Logger.root.level = LogDetail.fromId(FinampSettingsHelper.finampSettings.logLevel).effectiveLevel;
}
