import 'package:diapason/services/friendly_error.dart';

enum YtFailureKind {
  unavailable("video_unavailable"),
  ageRestricted("age_restricted"),
  blocked("youtube_blocked"),
  rateLimited("youtube_rate_limited"),
  network("network"),
  timeout("ytdlp_timeout"),
  jsRuntime("ytdlp_js_runtime"),
  outdated("ytdlp_outdated"),
  notInstalled("ytdlp_missing"),
  notRunnable("ytdlp_not_runnable"),
  badTarget("bad_target"),
  unsupported("unavailable_here"),
  failed("ytdlp_failed");

  const YtFailureKind(this.code);
  final String code;
}

class YtDlpFailure extends AppException {
  YtDlpFailure(this.kind, String message, {super.detail}) : super(message, source: ErrorSource.ytdlp, code: kind.code);

  final YtFailureKind kind;

  static YtDlpFailure classify(String stderr, {String where = "this computer"}) {
    final detail = _lastLine(stderr);
    final low = stderr.toLowerCase();
    bool has(List<String> needles) => needles.any(low.contains);
    YtDlpFailure mk(YtFailureKind k, String m) => YtDlpFailure(k, m, detail: detail);

    if (has(["confirm your age", "age-restricted", "age restricted", "inappropriate for some users"])) {
      return mk(
        YtFailureKind.ageRestricted,
        "This video is age-restricted. Signing in to YouTube through your browser's cookies (yt-dlp settings) may allow it.",
      );
    }
    if (has(["not a bot", "sign in to confirm", "login required", "please sign in"])) {
      return mk(
        YtFailureKind.blocked,
        "YouTube is asking $where to prove it isn't a bot. Try again later, use a VPN/proxy, or let yt-dlp borrow your browser's cookies.",
      );
    }
    if (has(["http error 429", "too many requests", "rate-limit", "rate limit"])) {
      return mk(YtFailureKind.rateLimited, "YouTube is rate-limiting $where. Wait a few minutes and try again.");
    }
    if (has([
      "private video",
      "video unavailable",
      "this video is not available",
      "has been removed",
      "no longer available",
      "not available in your country",
      "blocked it in your country",
      "copyright",
      "members-only",
      "join this channel",
      "terminated",
    ])) {
      return mk(
        YtFailureKind.unavailable,
        "YouTube says this video isn't available (private, removed, or blocked in your country).",
      );
    }
    if (has([
      "javascript runtime",
      "js runtime",
      "no supported javascript",
      "challenge solving failed",
      "n challenge",
    ])) {
      return mk(
        YtFailureKind.jsRuntime,
        "yt-dlp needs a JavaScript runtime (Deno) to read YouTube and none is available. Install it from the yt-dlp settings.",
      );
    }
    if (has([
      "requested format is not available",
      "no video formats",
      "unable to extract",
      "unsupported url",
      "sig function",
      "nsig",
    ])) {
      return mk(
        YtFailureKind.outdated,
        "yt-dlp couldn't read YouTube's response — it's probably out of date. Update it from the yt-dlp settings.",
      );
    }
    if (has([
      "unable to download",
      "temporary failure in name resolution",
      "name or service not known",
      "nodename nor servname",
      "connection refused",
      "connection reset",
      "network is unreachable",
      "no route to host",
      "timed out",
      "getaddrinfo",
      "certificate",
      "proxy",
    ])) {
      return mk(
        YtFailureKind.network,
        "yt-dlp couldn't reach YouTube from $where. Check the internet connection or the proxy setting.",
      );
    }
    return mk(YtFailureKind.failed, "yt-dlp failed on $where.");
  }

  static String _lastLine(String s) {
    s = s.trim();
    final i = s.lastIndexOf("\n");
    if (i >= 0) s = s.substring(i + 1);
    return s.length > 300 ? s.substring(0, 300) : s;
  }
}
