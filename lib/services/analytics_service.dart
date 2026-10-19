import 'dart:async';

import 'package:aptabase_flutter/aptabase_flutter.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:logging/logging.dart';

/// Thin wrapper around the self-hosted Aptabase instance. Usage counts and bug reports are two independent
/// opt-ins (both off by default); nothing is sent unless the matching setting is enabled.
class AnalyticsService {
  static const _appKey = "A-SH-8452187957";
  static const _host = "https://analytics.nytuo.fr";

  static final _log = Logger("Analytics");
  static bool _initialized = false;

  static Future<void> init() async {
    try {
      await Aptabase.init(_appKey, const InitOptions(host: _host));
      _initialized = true;
    } catch (e, st) {
      _log.warning("Failed to init analytics", e, st);
    }
  }

  /// Anonymous usage count, only if the user opted in to usage statistics.
  static void trackEvent(String name, [Map<String, dynamic>? props]) {
    if (!_initialized || !FinampSettingsHelper.finampSettings.analyticsEnabled) return;
    _send(name, props);
  }

  /// Anonymous error report, only if the user opted in to bug reports.
  static void reportError(Object error, StackTrace? stack) {
    if (!_initialized || !FinampSettingsHelper.finampSettings.bugReportsEnabled) return;
    _send("error", {
      "type": error.runtimeType.toString(),
      "message": _clean(error.toString(), 300),
      if (stack != null) "stack": _clean(stack.toString(), 450),
    });
  }

  static void _send(String name, Map<String, dynamic>? props) {
    try {
      unawaited(Aptabase.instance.trackEvent(name, props));
    } catch (e) {
      _log.fine("Failed to send analytics event: $e");
    }
  }

  /// Drops URLs (which may carry server addresses or tokens) and truncates.
  static String _clean(String text, int max) {
    final cleaned = text.replaceAll(RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://\S+'), "<url>");
    return cleaned.length <= max ? cleaned : cleaned.substring(0, max);
  }
}
