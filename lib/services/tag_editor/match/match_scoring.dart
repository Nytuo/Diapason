import 'dart:math';

import 'package:diacritic/diacritic.dart';

/// Fuzzy comparisons used to rank lookup candidates against what the file
/// already says. Everything returns 0..1.
abstract final class MatchScoring {
  static final _brackets = RegExp(r"[\(\[][^\)\]]*[\)\]]");
  static final _nonWord = RegExp(r"[^\p{L}\p{N}]+", unicode: true);

  static String normalize(String s, {bool dropBrackets = false}) {
    var out = removeDiacritics(s.toLowerCase()).replaceAll("&", " and ");
    if (dropBrackets) out = out.replaceAll(_brackets, " ");
    return out.replaceAll(_nonWord, " ").trim().replaceAll(RegExp(r"\s+"), " ");
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        current[j + 1] = min(min(current[j] + 1, previous[j + 1] + 1), previous[j] + cost);
      }
      previous = current;
    }
    return previous[b.length];
  }

  /// Best of edit-distance ratio and token overlap, also trying both strings
  /// without bracketed parts ("Song (Remastered 2011)" ≈ "Song").
  static double similarity(String? a, String? b) {
    if (a == null || b == null) return 0;
    double score(String x, String y) {
      if (x.isEmpty && y.isEmpty) return 1;
      if (x.isEmpty || y.isEmpty) return 0;
      final edit = 1 - _levenshtein(x, y) / max(x.length, y.length);
      final tx = x.split(" ").toSet();
      final ty = y.split(" ").toSet();
      final jaccard = tx.intersection(ty).length / tx.union(ty).length;
      return max(edit, jaccard);
    }

    final full = score(normalize(a), normalize(b));
    final stripped = score(normalize(a, dropBrackets: true), normalize(b, dropBrackets: true));
    // A bracket-only match is slightly less certain than an exact one.
    return max(full, stripped * 0.95);
  }

  /// 1 within 2 s, falling linearly to 0 at 15 s apart. Unknown → null.
  static double? durationScore(Duration? a, Duration? b) {
    if (a == null || b == null || a == Duration.zero || b == Duration.zero) return null;
    final diff = (a - b).inMilliseconds.abs() / 1000;
    if (diff <= 2) return 1;
    if (diff >= 15) return 0;
    return 1 - (diff - 2) / 13;
  }

  static double countScore(int? a, int? b) {
    if (a == null || b == null || a == 0 || b == 0) return 0.5;
    if (a == b) return 1;
    return max(0, 1 - (a - b).abs() / max(a, b) * 2);
  }

  /// Weighted mean over the components that are known (null = unknown, its
  /// weight is dropped instead of counting as a miss).
  static double weighted(List<(double?, double)> parts) {
    var total = 0.0;
    var weights = 0.0;
    for (final (value, weight) in parts) {
      if (value == null) continue;
      total += value * weight;
      weights += weight;
    }
    return weights == 0 ? 0 : total / weights;
  }

  /// Similarity of artist lists: each wanted name against its best candidate.
  static double? artistsSimilarity(List<String> wanted, List<String> candidate) {
    if (wanted.isEmpty) return null;
    if (candidate.isEmpty) return 0;
    final joined = candidate.join(" ");
    final perName = wanted.map((w) => max(candidate.map((c) => similarity(w, c)).reduce(max), similarity(w, joined)));
    return perName.reduce((a, b) => a + b) / wanted.length;
  }
}
