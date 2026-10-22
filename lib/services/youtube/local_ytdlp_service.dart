import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/youtube/yt_entry.dart';
import 'package:diapason/services/youtube/ytdlp_config.dart';
import 'package:diapason/services/youtube/ytdlp_errors.dart';
import 'package:diapason/services/youtube/ytdlp_installer.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

enum LocalYtDlpState { unsupported, checking, notInstalled, ready, broken }

enum YtDlpOrigin { managed, custom, system }

class LocalYtDlpStatus {
  const LocalYtDlpStatus({
    this.state = LocalYtDlpState.checking,
    this.version,
    this.path,
    this.origin,
    this.jsRuntime,
    this.jsRuntimePath,
    this.jsRuntimeManaged = false,
    this.problem,
    this.latestVersion,
  });

  final LocalYtDlpState state;
  final String? version;
  final String? path;
  final YtDlpOrigin? origin;

  final String? jsRuntime;
  final String? jsRuntimePath;
  final bool jsRuntimeManaged;
  final String? problem;

  final String? latestVersion;

  bool get isReady => state == LocalYtDlpState.ready;
  bool get updateAvailable =>
      isReady && latestVersion != null && version != null && latestVersion!.compareTo(version!) > 0;
}

class LocalYtDlpService {
  LocalYtDlpService({YtDlpInstaller? installer}) : installer = installer ?? YtDlpInstaller();

  static final _log = Logger("LocalYtDlpService");
  static final _idRe = RegExp(r"^[A-Za-z0-9_-]{11}$");

  final ValueNotifier<LocalYtDlpStatus> status = ValueNotifier(
    YtDlpPaths.isDesktop ? const LocalYtDlpStatus() : const LocalYtDlpStatus(state: LocalYtDlpState.unsupported),
  );
  final ValueNotifier<YtDlpConfig> config = ValueNotifier(YtDlpConfig());

  final YtDlpInstaller installer;

  static bool get supported => YtDlpPaths.isDesktop && YtDlpPaths.execBlockedReason == null;

  static const _maxParallel = 3;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  Future<void> init() async {
    if (!supported) return;
    config.value = YtDlpConfig.decode(FinampSettingsHelper.finampSettings.ytdlpConfigJson);
    await refresh();
    if (config.value.autoUpdate && status.value.isReady && status.value.origin == YtDlpOrigin.managed) {
      unawaited(maybeAutoUpdate());
    }
  }

  Future<void> saveConfig(YtDlpConfig next) async {
    config.value = next;
    FinampSetters.setYtdlpConfigJson(next.encode());
    await refresh();
  }

  Future<void> refresh() async {
    if (!supported) return;
    final previous = status.value;
    status.value = LocalYtDlpStatus(state: LocalYtDlpState.checking, latestVersion: previous.latestVersion);

    if (!await YtDlpPaths.canRunDownloadedPrograms()) {
      _log.warning("Can't run yt-dlp here: ${YtDlpPaths.execBlockedReason}");
      status.value = LocalYtDlpStatus(state: LocalYtDlpState.unsupported, problem: YtDlpPaths.execBlockedReason);
      return;
    }
    _log.fine("Running downloaded programs is allowed on this build");

    final found = await _findYtDlp();
    final js = await _findJsRuntime();

    if (found == null) {
      _log.info("yt-dlp not found (custom='${config.value.customBinaryPath}')");
      status.value = LocalYtDlpStatus(
        state: LocalYtDlpState.notInstalled,
        jsRuntime: js?.name,
        jsRuntimePath: js?.path,
        jsRuntimeManaged: js?.managed ?? false,
      );
      return;
    }

    try {
      final out = await _exec(found.path, ["--version"], timeout: const Duration(seconds: 20));
      final version = out.trim().split("\n").first;
      _log.info("yt-dlp $version at ${found.path} (${found.origin.name}); JS runtime: ${js?.name ?? "none"}");
      status.value = LocalYtDlpStatus(
        state: LocalYtDlpState.ready,
        version: version,
        path: found.path,
        origin: found.origin,
        jsRuntime: js?.name,
        jsRuntimePath: js?.path,
        jsRuntimeManaged: js?.managed ?? false,
        latestVersion: previous.latestVersion,
      );
    } catch (e, stack) {
      final message = FriendlyError.report(_log, "Running yt-dlp at ${found.path}", e, stack);
      status.value = LocalYtDlpStatus(
        state: LocalYtDlpState.broken,
        path: found.path,
        origin: found.origin,
        problem: "yt-dlp was found at ${found.path} but won't run: $message",
        jsRuntime: js?.name,
        jsRuntimePath: js?.path,
        jsRuntimeManaged: js?.managed ?? false,
      );
    }
  }

  Future<({String path, YtDlpOrigin origin})?> _findYtDlp() async {
    final custom = config.value.customBinaryPath.trim();
    if (custom.isNotEmpty) {
      if (File(custom).existsSync()) return (path: custom, origin: YtDlpOrigin.custom);
      _log.warning("Custom yt-dlp path '$custom' doesn't exist");
    }
    final managed = await YtDlpPaths.managedYtDlp();
    if (managed.existsSync()) return (path: managed.path, origin: YtDlpOrigin.managed);
    final system = YtDlpPaths.which("yt-dlp");
    if (system != null) return (path: system, origin: YtDlpOrigin.system);
    return null;
  }

  Future<({String name, String path, bool managed})?> _findJsRuntime() async {
    final want = config.value.jsRuntime;
    if (want == "none") return null;
    if (want == "auto" || want == "deno") {
      final managed = await YtDlpPaths.managedDeno();
      if (managed.existsSync()) return (name: "deno", path: managed.path, managed: true);
    }
    final order = want == "auto" ? ["deno", "node", "bun"] : [want];
    for (final name in order) {
      final path = YtDlpPaths.which(name);
      if (path != null) return (name: name, path: path, managed: false);
    }
    return null;
  }

  Future<void> checkForUpdate() async {
    final latest = await installer.latestYtDlpVersion();
    final cfg = config.value..lastUpdateCheckMs = DateTime.now().millisecondsSinceEpoch;
    FinampSetters.setYtdlpConfigJson(cfg.encode());
    final s = status.value;
    status.value = LocalYtDlpStatus(
      state: s.state,
      version: s.version,
      path: s.path,
      origin: s.origin,
      jsRuntime: s.jsRuntime,
      jsRuntimePath: s.jsRuntimePath,
      jsRuntimeManaged: s.jsRuntimeManaged,
      problem: s.problem,
      latestVersion: latest,
    );
  }

  Future<void> maybeAutoUpdate() async {
    final last = DateTime.fromMillisecondsSinceEpoch(config.value.lastUpdateCheckMs);
    if (DateTime.now().difference(last) < const Duration(hours: 24)) return;
    try {
      await checkForUpdate();
      if (status.value.updateAvailable) {
        _log.info("Updating yt-dlp ${status.value.version} -> ${status.value.latestVersion}");
        await installer.install(ytdlp: true, jsRuntime: false, onUpdate: (_) {});
        await refresh();
      }
    } catch (e, stack) {
      FriendlyError.report(_log, "Automatic yt-dlp update", e, stack);
    }
  }

  Future<void> _acquire() async {
    if (_running < _maxParallel) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  List<String> globalArgs() {
    final cfg = config.value;
    final s = status.value;
    return [
      "--no-warnings",
      "--no-colors",
      ...cfg.globalArgs(),
      if (s.jsRuntime != null && s.jsRuntimePath != null) ...["--js-runtimes", "${s.jsRuntime}:${s.jsRuntimePath}"],
    ];
  }

  String previewCommand(List<String> operation) =>
      "${status.value.path ?? "yt-dlp"} ${YtDlpConfig.joinArgs([...globalArgs(), ...operation])}";

  Future<String> _exec(String path, List<String> args, {Duration timeout = const Duration(seconds: 60)}) async {
    final process = await Process.start(path, args, environment: await _environment());
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    const cap = 16 << 20;
    process.stdout.listen((d) {
      if (out.length < cap) out.add(d);
    });
    process.stderr.listen((d) {
      if (err.length < (256 << 10)) err.add(d);
    });
    final exit = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw YtDlpFailure(YtFailureKind.timeout, "yt-dlp took too long on this computer and was stopped.");
      },
    );
    final stdout = utf8.decode(out.takeBytes(), allowMalformed: true);
    final stderr = utf8.decode(err.takeBytes(), allowMalformed: true);
    if (exit != 0) {
      _log.warning("yt-dlp exited $exit: ${stderr.trim().split("\n").take(6).join(" | ")}");
      throw YtDlpFailure.classify(stderr);
    }
    if (stderr.trim().isNotEmpty) _log.fine("yt-dlp stderr: ${stderr.trim()}");
    return stdout;
  }

  Future<Map<String, String>> _environment() async {
    final managed = (await YtDlpPaths.managedDir()).path;
    final sep = Platform.isWindows ? ";" : ":";
    return {"PATH": "$managed$sep${Platform.environment["PATH"] ?? ""}", "PYTHONIOENCODING": "utf-8"};
  }

  Future<String> run(List<String> operation, {Duration timeout = const Duration(seconds: 60)}) async {
    final s = status.value;
    if (s.state == LocalYtDlpState.unsupported) {
      throw YtDlpFailure(YtFailureKind.unsupported, "Running yt-dlp isn't possible on this device.");
    }
    if (!s.isReady || s.path == null) {
      throw YtDlpFailure(
        s.state == LocalYtDlpState.broken ? YtFailureKind.notRunnable : YtFailureKind.notInstalled,
        s.problem ?? "yt-dlp isn't installed on this computer. Set it up in Settings → YouTube (yt-dlp).",
      );
    }
    await _acquire();
    try {
      final args = [...globalArgs(), ...operation];
      _log.fine("yt-dlp ${YtDlpConfig.joinArgs(args)}");
      return await _exec(s.path!, args, timeout: timeout);
    } finally {
      _release();
    }
  }

  static String watchUrl(String id) => "https://www.youtube.com/watch?v=$id";

  static String? parseVideoId(String input) {
    final s = input.trim();
    if (_idRe.hasMatch(s)) return s;
    final uri = Uri.tryParse(s);
    if (uri == null || !(uri.isScheme("https") || uri.isScheme("http"))) return null;
    String? id;
    switch (uri.host.toLowerCase()) {
      case "youtu.be":
        id = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
      case "youtube.com" || "www.youtube.com" || "m.youtube.com" || "music.youtube.com":
        if (uri.path == "/watch") {
          id = uri.queryParameters["v"];
        } else if (uri.pathSegments.length >= 2 && const {"shorts", "embed", "live"}.contains(uri.pathSegments.first)) {
          id = uri.pathSegments[1];
        }
    }
    return id != null && _idRe.hasMatch(id) ? id : null;
  }

  List<YtEntry> _entries(String json) {
    final doc = jsonDecode(json) as Map<String, dynamic>;
    final entries = <YtEntry>[];
    for (final e in (doc["entries"] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = e["id"] as String?;
      final title = e["title"] as String?;
      if (id == null || !_idRe.hasMatch(id) || title == null || title.isEmpty) continue;
      entries.add(
        YtEntry(
          id: id,
          title: title,
          artist: _cleanArtist((e["channel"] as String?) ?? (e["uploader"] as String?) ?? ""),
          durationSecs: (e["duration"] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return entries;
  }

  static String _cleanArtist(String s) =>
      s.trim().replaceFirst(RegExp(r" - Topic$"), "").replaceFirst(RegExp(r"VEVO$"), "").trim();

  Future<List<YtEntry>> search(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final out = await run([
      "--flat-playlist",
      "-J",
      "--skip-download",
      "--",
      "ytsearch$limit:${q.length > 200 ? q.substring(0, 200) : q}",
    ]);
    return _entries(out);
  }

  Future<List<YtEntry>> playlist(String url, {int limit = 50}) async {
    final out = await run(["--flat-playlist", "-J", "--skip-download", "--playlist-end", "$limit", "--", url]);
    return _entries(out);
  }

  Future<YtEntry?> lookup(String id) async {
    if (!_idRe.hasMatch(id)) return null;
    final out = await run(["--no-playlist", "--skip-download", "-J", "--", watchUrl(id)]);
    final j = jsonDecode(out) as Map<String, dynamic>;
    final vid = j["id"] as String?;
    if (vid == null) return null;
    return YtEntry(
      id: vid,
      title: ((j["track"] as String?)?.isNotEmpty ?? false) ? j["track"] as String : (j["title"] as String? ?? ""),
      artist: _cleanArtist((j["artist"] as String?) ?? (j["channel"] as String?) ?? (j["uploader"] as String?) ?? ""),
      durationSecs: (j["duration"] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<YtEntry>> mix(String id, {int limit = 50}) async {
    if (!_idRe.hasMatch(id)) return const [];
    final out = await run([
      "--flat-playlist",
      "-J",
      "--skip-download",
      "--playlist-end",
      "$limit",
      "--",
      "https://www.youtube.com/watch?v=$id&list=RD$id",
    ]);
    return _entries(out).where((e) => e.id != id).toList();
  }

  Future<List<YtEntry>> related(String id, {int limit = 20}) async {
    try {
      final mixed = await mix(id, limit: limit + 1);
      if (mixed.isNotEmpty) return mixed.take(limit).toList();
    } on YtDlpFailure catch (e) {
      if (e.kind == YtFailureKind.rateLimited || e.kind == YtFailureKind.blocked) rethrow;
      _log.fine("YouTube Mix unavailable for $id (${e.kind.name}); falling back to a text search");
    }
    final seed = await lookup(id);
    if (seed == null) return const [];
    final results = await search("${seed.artist} ${seed.title}".trim(), limit: limit + 1);
    return results.where((e) => e.id != id).take(limit).toList();
  }

  final Map<String, ({Uri url, String ext, DateTime at})> _streamCache = {};

  Future<({Uri url, String ext})> streamUrl(String id) async {
    if (!_idRe.hasMatch(id)) {
      throw YtDlpFailure(YtFailureKind.badTarget, "That isn't a YouTube video.");
    }
    final cached = _streamCache[id];
    if (cached != null && DateTime.now().difference(cached.at) < const Duration(minutes: 5)) {
      return (url: cached.url, ext: cached.ext);
    }
    final out = await run([
      "--no-playlist",
      "-f",
      config.value.audio.format,
      "--print",
      "%(url)s",
      "--print",
      "%(ext)s",
      "--",
      watchUrl(id),
    ]);
    final lines = const LineSplitter().convert(out).where((l) => l.trim().isNotEmpty).toList();
    final url = lines.isEmpty ? null : Uri.tryParse(lines.first.trim());
    if (url == null || !url.isScheme("https")) {
      throw YtDlpFailure(
        YtFailureKind.outdated,
        "yt-dlp didn't return a playable address — it may be out of date. Update it from the yt-dlp settings.",
        detail: lines.isEmpty ? "no output" : lines.first,
      );
    }
    final ext = lines.length > 1 ? lines[1].trim() : "m4a";
    _streamCache[id] = (url: url, ext: ext, at: DateTime.now());
    return (url: url, ext: ext);
  }

  Future<String> selfTest() async {
    final started = DateTime.now();
    final entry = await lookup("jNQXAC9IVRw");
    if (entry == null) throw YtDlpFailure(YtFailureKind.failed, "yt-dlp ran but returned nothing.");
    await streamUrl(entry.id);
    final ms = DateTime.now().difference(started).inMilliseconds;
    return "Worked: found “${entry.title}” and resolved its audio in ${(ms / 1000).toStringAsFixed(1)} s.";
  }
}
