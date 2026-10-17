import 'dart:convert';

enum YtAudioPreference {
  m4a("Best AAC (m4a)", "bestaudio[ext=m4a]/bestaudio"),

  opus("Best Opus (webm)", "bestaudio[ext=webm]/bestaudio"),

  best("Best available", "bestaudio");

  const YtAudioPreference(this.label, this.format);
  final String label;
  final String format;
}

class YtDlpConfig {
  YtDlpConfig();

  factory YtDlpConfig.fromJson(Map<String, dynamic> json) {
    final c = YtDlpConfig();
    c.autoUpdate = json["autoUpdate"] as bool? ?? c.autoUpdate;
    c.preferUploader = json["preferUploader"] as bool? ?? c.preferUploader;
    c.customBinaryPath = json["customBinaryPath"] as String? ?? "";
    c.jsRuntime = json["jsRuntime"] as String? ?? c.jsRuntime;
    c.audio = YtAudioPreference.values.firstWhere((e) => e.name == json["audio"], orElse: () => YtAudioPreference.m4a);
    c.proxy = json["proxy"] as String? ?? "";
    c.cookiesFromBrowser = json["cookiesFromBrowser"] as String? ?? "";
    c.cookiesFile = json["cookiesFile"] as String? ?? "";
    c.rateLimit = json["rateLimit"] as String? ?? "";
    c.socketTimeoutSecs = (json["socketTimeoutSecs"] as num?)?.toInt() ?? c.socketTimeoutSecs;
    c.retries = (json["retries"] as num?)?.toInt() ?? c.retries;
    c.forceIpv4 = json["forceIpv4"] as bool? ?? false;
    c.geoBypassCountry = json["geoBypassCountry"] as String? ?? "";
    c.extractorArgs = json["extractorArgs"] as String? ?? "";
    c.extraArgs = json["extraArgs"] as String? ?? "";
    c.advancedMode = json["advancedMode"] as bool? ?? false;
    c.advancedArgs = json["advancedArgs"] as String? ?? "";
    c.promptDismissed = json["promptDismissed"] as bool? ?? false;
    c.lastUpdateCheckMs = (json["lastUpdateCheckMs"] as num?)?.toInt() ?? 0;
    return c;
  }

  factory YtDlpConfig.decode(String? source) {
    if (source == null || source.isEmpty) return YtDlpConfig();
    try {
      return YtDlpConfig.fromJson(jsonDecode(source) as Map<String, dynamic>);
    } catch (_) {
      return YtDlpConfig();
    }
  }

  bool autoUpdate = true;

  bool preferUploader = false;

  String customBinaryPath = "";

  String jsRuntime = "auto";

  YtAudioPreference audio = YtAudioPreference.m4a;

  String proxy = "";

  String cookiesFromBrowser = "";
  String cookiesFile = "";

  String rateLimit = "";
  int socketTimeoutSecs = 20;
  int retries = 3;
  bool forceIpv4 = false;

  String geoBypassCountry = "";

  String extractorArgs = "";

  String extraArgs = "";

  bool advancedMode = false;
  String advancedArgs = "";

  bool promptDismissed = false;
  int lastUpdateCheckMs = 0;

  Map<String, dynamic> toJson() => {
    "autoUpdate": autoUpdate,
    "preferUploader": preferUploader,
    "customBinaryPath": customBinaryPath,
    "jsRuntime": jsRuntime,
    "audio": audio.name,
    "proxy": proxy,
    "cookiesFromBrowser": cookiesFromBrowser,
    "cookiesFile": cookiesFile,
    "rateLimit": rateLimit,
    "socketTimeoutSecs": socketTimeoutSecs,
    "retries": retries,
    "forceIpv4": forceIpv4,
    "geoBypassCountry": geoBypassCountry,
    "extractorArgs": extractorArgs,
    "extraArgs": extraArgs,
    "advancedMode": advancedMode,
    "advancedArgs": advancedArgs,
    "promptDismissed": promptDismissed,
    "lastUpdateCheckMs": lastUpdateCheckMs,
  };

  String encode() => jsonEncode(toJson());

  YtDlpConfig clone() => YtDlpConfig.fromJson(toJson());

  List<String> visualArgs() => [
    if (proxy.trim().isNotEmpty) ...["--proxy", proxy.trim()],
    if (cookiesFromBrowser.trim().isNotEmpty) ...["--cookies-from-browser", cookiesFromBrowser.trim()],
    if (cookiesFile.trim().isNotEmpty) ...["--cookies", cookiesFile.trim()],
    if (rateLimit.trim().isNotEmpty) ...["--limit-rate", rateLimit.trim()],
    "--socket-timeout",
    "$socketTimeoutSecs",
    "--retries",
    "$retries",
    if (forceIpv4) "--force-ipv4",
    if (geoBypassCountry.trim().isNotEmpty) ...["--geo-bypass-country", geoBypassCountry.trim().toUpperCase()],
    if (extractorArgs.trim().isNotEmpty) ...["--extractor-args", extractorArgs.trim()],
    ...splitArgs(extraArgs),
  ];

  List<String> globalArgs() => advancedMode ? splitArgs(advancedArgs) : ["--ignore-config", ...visualArgs()];

  String visualAsCommandLine() => joinArgs(["--ignore-config", ...visualArgs()]);

  static List<String> splitArgs(String input) {
    final args = <String>[];
    final current = StringBuffer();
    var inToken = false;
    String? quote;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else if (ch == r"\" &&
            quote == '"' &&
            i + 1 < input.length &&
            (input[i + 1] == '"' || input[i + 1] == r"\")) {
          current.write(input[++i]);
        } else {
          current.write(ch);
        }
      } else if (ch == '"' || ch == "'") {
        quote = ch;
        inToken = true;
      } else if (ch == " " || ch == "\t" || ch == "\n" || ch == "\r") {
        if (inToken) {
          args.add(current.toString());
          current.clear();
          inToken = false;
        }
      } else {
        current.write(ch);
        inToken = true;
      }
    }
    if (inToken) args.add(current.toString());
    return args;
  }

  static String joinArgs(List<String> args) => args
      .map(
        (a) => a.isEmpty || RegExp(r"""[\s"']""").hasMatch(a)
            ? '"${a.replaceAll(r"\", r"\\").replaceAll('"', r'\"')}"'
            : a,
      )
      .join(" ");
}
