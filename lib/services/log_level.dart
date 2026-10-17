import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:logging/logging.dart';

/// The user-selectable detail of the in-app log.
enum LogDetail {
  all("all", "Everything", "Most detail. Best for bug reports; the log file grows faster.", Level.ALL),
  info("info", "Normal", "Notable events and problems.", Level.INFO),
  warning("warning", "Problems only", "Only warnings and errors.", Level.WARNING);

  const LogDetail(this.id, this.label, this.description, this.level);

  final String id;
  final String label;
  final String description;
  final Level level;

  static LogDetail fromId(String id) => values.firstWhere((d) => d.id == id, orElse: () => LogDetail.all);
}

/// Applies the saved log detail to the root logger.
void applyConfiguredLogLevel() {
  Logger.root.level = LogDetail.fromId(FinampSettingsHelper.finampSettings.logLevel).level;
}
