import 'dart:convert';
import 'dart:io' hide Platform;

import 'package:diapason/utils/platform.dart';

import 'package:diapason/services/tag_editor/match/lookup_http.dart';
import 'package:logging/logging.dart';

enum AcoustIdAvailability { available, notDesktop, noFpcalc, noApiKey }

class AcoustIdMatch {
  const AcoustIdMatch(this.score, this.recordingIds);

  /// AcoustID's 0..1 fingerprint match score.
  final double score;
  final List<String> recordingIds;
}

/// Acoustic fingerprint lookup. Needs Chromaprint's `fpcalc` (desktop only)
/// and an AcoustID application API key; nothing is faked when either is missing.
class AcoustIdClient {
  AcoustIdClient(this._http, {this.fpcalcPath});

  final LookupHttp _http;
  static final _log = Logger("AcoustId");

  /// Overrides the PATH lookup (tests).
  final String? fpcalcPath;
  String? _resolvedFpcalc;

  static bool get isDesktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  Future<String?> findFpcalc() async {
    if (fpcalcPath != null) return fpcalcPath;
    if (_resolvedFpcalc != null) return _resolvedFpcalc;
    final exe = Platform.isWindows ? "fpcalc.exe" : "fpcalc";
    final candidates = [
      // GUI apps on macOS don't inherit the shell PATH.
      if (Platform.isMacOS) ...["/opt/homebrew/bin/$exe", "/usr/local/bin/$exe"],
      if (Platform.isLinux) ...["/usr/bin/$exe", "/usr/local/bin/$exe"],
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return _resolvedFpcalc = c;
    }
    try {
      final which = await Process.run(Platform.isWindows ? "where" : "which", [exe]);
      final path = (which.stdout as String).split(RegExp(r"[\r\n]+")).firstOrNull?.trim();
      if (which.exitCode == 0 && path != null && path.isNotEmpty) return _resolvedFpcalc = path;
    } catch (_) {}
    return null;
  }

  Future<AcoustIdAvailability> availability(String apiKey) async {
    if (!isDesktop) return AcoustIdAvailability.notDesktop;
    if (await findFpcalc() == null) return AcoustIdAvailability.noFpcalc;
    if (apiKey.trim().isEmpty) return AcoustIdAvailability.noApiKey;
    return AcoustIdAvailability.available;
  }

  Future<({int duration, String fingerprint})> fingerprint(File file) async {
    final fpcalc = await findFpcalc();
    if (fpcalc == null) throw StateError("fpcalc not found");
    final result = await Process.run(fpcalc, ["-json", file.path]);
    if (result.exitCode != 0) throw ProcessException(fpcalc, ["-json", file.path], "${result.stderr}", result.exitCode);
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    return (duration: (json["duration"] as num).round(), fingerprint: json["fingerprint"] as String);
  }

  Future<List<AcoustIdMatch>> lookup(File file, String apiKey) async {
    final fp = await fingerprint(file);
    final response = await _http.post(
      Uri.https("api.acoustid.org", "/v2/lookup"),
      body: {
        "client": apiKey.trim(),
        "meta": "recordingids",
        "duration": "${fp.duration}",
        "fingerprint": fp.fingerprint,
        "format": "json",
      },
    );
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200 || (json as Map)["status"] != "ok") {
      _log.warning("AcoustID lookup failed: HTTP ${response.statusCode} ${json is Map ? json["error"] : ""}");
      throw LookupException("api.acoustid.org", response.statusCode);
    }
    return parseLookup(json);
  }

  static List<AcoustIdMatch> parseLookup(dynamic json) {
    final results = ((json as Map?)?["results"] as List? ?? const []).cast<Map<String, dynamic>>();
    return [
      for (final r in results)
        if ((r["recordings"] as List?)?.isNotEmpty ?? false)
          AcoustIdMatch((r["score"] as num?)?.toDouble() ?? 0, [
            for (final rec in (r["recordings"] as List).cast<Map<String, dynamic>>()) rec["id"] as String,
          ]),
    ]..sort((a, b) => b.score.compareTo(a.score));
  }
}
