import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/downloads_service.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube_service.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Puts YouTube tracks into the user's own library through the uploader, when the user keeps them (downloads one,
/// adds one to a playlist) — never just for listening to or previewing one.
///
/// When the uploader runs yt-dlp itself it is asked to fetch the track (nothing goes through this device);
/// otherwise this device sends the file: the downloaded one, or a copy of the stream fetched for the purpose.
class YouTubeLibraryImport {
  YouTubeLibraryImport({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static final _log = Logger("YouTubeLibraryImport");

  /// How long to wait for an imported track to show up in the library (the server has to scan it in).
  static const _appearTimeout = Duration(minutes: 15);
  static const _appearPoll = Duration(seconds: 20);

  final http.Client _http;

  /// Imports that failed because the uploader couldn't be reached, retried later (kept across launches).
  final List<({BaseItemDto track, BaseItemDto? playlist})> _pending = [];
  Timer? _retryTimer;
  bool _retrying = false;
  static const _retryEvery = Duration(minutes: 10);

  /// Loads imports left over from earlier and starts retrying them now and then.
  Future<void> start() async {
    try {
      final file = await _pendingFile();
      if (file.existsSync()) {
        final list = jsonDecode(await file.readAsString()) as List;
        for (final entry in list.cast<Map<String, dynamic>>()) {
          _pending.add((
            track: BaseItemDto.fromJson((entry["track"] as Map).cast<String, dynamic>()),
            playlist: entry["playlist"] == null
                ? null
                : BaseItemDto.fromJson((entry["playlist"] as Map).cast<String, dynamic>()),
          ));
        }
      }
    } catch (e) {
      _log.fine("Couldn't read pending imports: $e");
    }
    _retryTimer ??= Timer.periodic(_retryEvery, (_) => unawaited(retryPending()));
    if (_pending.isNotEmpty) {
      Timer(const Duration(seconds: 30), () => unawaited(retryPending()));
    }
  }

  int get pendingCount => _pending.length;

  Future<File> _pendingFile() async =>
      File(p.join((await getApplicationSupportDirectory()).path, "uploader", "pending_youtube_imports.json"));

  Future<void> _savePending() async {
    try {
      final file = await _pendingFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode([
          for (final entry in _pending) {"track": entry.track.toJson(), "playlist": entry.playlist?.toJson()},
        ]),
      );
    } catch (e) {
      _log.fine("Couldn't save pending imports: $e");
    }
  }

  void _queue(BaseItemDto track, BaseItemDto? playlist) {
    if (_pending.any((e) => e.track.id == track.id && e.playlist?.id == playlist?.id)) return;
    _pending.add((track: track, playlist: playlist));
    _log.info("Will retry adding '${track.name}' to the library when the uploader is reachable");
    unawaited(_savePending());
  }

  /// Tries the imports that are waiting for the uploader again.
  Future<void> retryPending() async {
    if (_retrying || _pending.isEmpty || !_uploader.isReady) return;
    _retrying = true;
    try {
      if (!(await _uploader.capabilities()).reachable) return;
      for (final entry in [..._pending]) {
        final result = await addToLibrary(entry.track, automatic: true, queueOnFailure: false);
        if (result.ok || !_isUnreachable(result)) {
          _pending.remove(entry);
          if (result.ok && entry.playlist != null) unawaited(_addOnceInLibrary(entry.playlist!, entry.track));
          if (result.ok)
            GlobalSnackbar.message((_) => "Added '${entry.track.name}' to your library", isConfirmation: true);
        }
      }
      await _savePending();
    } finally {
      _retrying = false;
    }
  }

  static bool _isUnreachable(UploadResult result) => !result.ok && result.source == ErrorSource.connection;

  UploaderClient get _uploader => GetIt.instance<UploaderClient>();

  bool? _serverFetches;
  DateTime? _checkedAt;

  static bool isYouTube(BaseItemDto item) => item.id.sourceId == YouTubeService.sourceId;

  bool get available => _uploader.isReady;

  /// Whether the uploader can download from YouTube itself (checked at most every five minutes).
  Future<bool> serverFetches() async {
    final checked = _checkedAt;
    if (_serverFetches != null && checked != null && DateTime.now().difference(checked) < const Duration(minutes: 5)) {
      return _serverFetches!;
    }
    final capabilities = await _uploader.capabilities();
    _checkedAt = DateTime.now();
    return _serverFetches = capabilities.reachable && capabilities.ytdlp;
  }

  /// Adds [track] (a YouTube track) to the library. [file] is the track's audio if this device already has it.
  /// [automatic] transfers respect "only on Wi-Fi" for what this device would have to send.
  Future<UploadResult> addToLibrary(
    BaseItemDto track, {
    File? file,
    bool automatic = false,
    bool queueOnFailure = true,
    BaseItemDto? forPlaylist,
  }) async {
    final result = await _addToLibrary(track, file: file, automatic: automatic);
    if (queueOnFailure && _isUnreachable(result)) _queue(track, forPlaylist);
    return result;
  }

  Future<UploadResult> _addToLibrary(BaseItemDto track, {File? file, bool automatic = false}) async {
    if (!_uploader.isReady) {
      return const UploadResult.failed(
        "Set up the uploader to add YouTube tracks to your library.",
        source: ErrorSource.uploader,
      );
    }
    final artist = track.albumArtist ?? track.artists?.firstOrNull;

    final capabilities = await _uploader.capabilities();
    _serverFetches = capabilities.reachable && capabilities.ytdlp;
    _checkedAt = DateTime.now();
    if (!capabilities.reachable) {
      // Sending the file would fail the same way; try again once the uploader is back.
      return UploadResult.failed(
        capabilities.problem ?? "The uploader can't be reached.",
        source: capabilities.state == UploaderState.unreachable ? ErrorSource.connection : ErrorSource.uploader,
      );
    }
    if (capabilities.ytdlp) {
      _log.info("Asking the uploader to fetch '${track.name}' from YouTube");
      return _uploader.ytDownloadToLibrary(track.id.nativeId, artist: artist, title: track.name);
    }

    if (automatic && !await _uploader.automaticTransferAllowed()) {
      return const UploadResult.failed("Waiting for Wi-Fi to send it to your library.", source: ErrorSource.device);
    }

    file ??= GetIt.instance<DownloadsService>().getTrackDownload(item: track)?.file;
    File? temporary;
    if (file == null || !file.existsSync()) {
      temporary = await _fetchToTemporary(track);
      if (temporary == null) {
        return const UploadResult.failed("Couldn't get that track from YouTube.", source: ErrorSource.ytdlp);
      }
      file = temporary;
    }
    try {
      _log.info("Uploading '${track.name}' from this device");
      return await _uploader.uploadFile(file, artist: artist ?? "", title: track.name ?? "");
    } finally {
      if (temporary != null && temporary.existsSync()) temporary.deleteSync();
    }
  }

  Future<File?> _fetchToTemporary(BaseItemDto track) async {
    try {
      final backend = GetIt.instance<BackendRegistry>().forItem(track);
      if (backend == null) return null;
      final source = await backend.resolveDownload(track);
      final ext = (source.container?.isNotEmpty ?? false) ? source.container! : "m4a";
      final file = File(p.join((await getTemporaryDirectory()).path, "diapason-yt-${track.id.nativeId}.$ext"));
      final request = http.Request("GET", source.uri)..headers.addAll(source.headers);
      final response = await _http.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      final sink = file.openWrite();
      await response.stream.pipe(sink);
      return file;
    } catch (e) {
      _log.warning("Couldn't fetch '${track.name}' to send it to the library: $e");
      return null;
    }
  }

  /// Adds YouTube [tracks] to [playlist]: each goes into the library first, and is added to the playlist once the
  /// library has it. Runs in the background and reports through snackbars.
  Future<void> addToPlaylist(BaseItemDto playlist, List<BaseItemDto> tracks) async {
    for (final track in tracks) {
      final result = await addToLibrary(track, forPlaylist: playlist);
      if (!result.ok) {
        GlobalSnackbar.message(
          (_) => _isUnreachable(result)
              ? "Can't reach the uploader. '${track.name}' will be added to ${playlist.name} once it's back."
              : "Couldn't add '${track.name}' to your library: ${result.message}",
        );
        continue;
      }
      unawaited(_addOnceInLibrary(playlist, track));
    }
  }

  Future<void> _addOnceInLibrary(BaseItemDto playlist, BaseItemDto track) async {
    final backend = GetIt.instance<BackendRegistry>().forItem(playlist);
    if (backend == null) return;
    final deadline = DateTime.now().add(_appearTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final found = await findInLibrary(
          track,
          (search) => backend.getItems(includeItemTypes: "Audio", searchTerm: search, limit: 25),
        );
        if (found != null) {
          await backend.addToPlaylist(playlist, [found.id]);
          _log.info("Added '${found.name}' (from YouTube) to '${playlist.name}'");
          GlobalSnackbar.message((_) => "Added '${found.name}' to ${playlist.name}", isConfirmation: true);
          return;
        }
      } catch (e) {
        _log.fine("Looking for '${track.name}' in the library failed: $e");
      }
      await Future<void>.delayed(_appearPoll);
    }
    GlobalSnackbar.message(
      (_) =>
          "'${track.name}' is not in your library yet, so it wasn't added to ${playlist.name}. Add it once it shows up.",
    );
  }

  /// The library track that [youtube] became, searched with [search]. The uploader may have cleaned the title up
  /// ("Artist - Song (Official Video)" → "Song"), so matching is by words, not exact text.
  static Future<BaseItemDto?> findInLibrary(
    BaseItemDto youtube,
    Future<List<BaseItemDto>> Function(String search) search,
  ) async {
    final title = cleanTitle(youtube.name ?? "", artist: youtube.albumArtist);
    if (title.isEmpty) return null;
    final candidates = await search(title);
    BaseItemDto? best;
    var bestScore = 0.0;
    for (final candidate in candidates) {
      if (isYouTube(candidate)) continue;
      final score = _similarity(title, candidate.name ?? "");
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return bestScore >= 0.6 ? best : null;
  }

  static final _noise = RegExp(
    r"[\(\[]\s*(official|lyric|lyrics|audio|video|music video|visualizer|hd|hq|4k|mv|remastered[^\)\]]*)[^\)\]]*[\)\]]",
    caseSensitive: false,
  );

  /// The song's title out of a YouTube title: without "(Official Video)" and the like, and without a leading
  /// "Artist - ".
  static String cleanTitle(String title, {String? artist}) {
    var t = title.replaceAll(_noise, " ").replaceAll(RegExp(r"\s+"), " ").trim();
    final dash = t.indexOf(" - ");
    if (dash > 0) {
      final before = t.substring(0, dash).toLowerCase();
      final a = artist?.toLowerCase().replaceAll(" - topic", "").trim();
      if (a == null || a.isEmpty || before.contains(a) || a.contains(before)) t = t.substring(dash + 3).trim();
    }
    return t;
  }

  static Set<String> _words(String s) =>
      s.toLowerCase().split(RegExp(r"[^\p{L}\p{N}]+", unicode: true)).where((w) => w.isNotEmpty).toSet();

  static double _similarity(String a, String b) {
    final wa = _words(a);
    final wb = _words(b);
    if (wa.isEmpty || wb.isEmpty) return 0;
    return wa.intersection(wb).length / (wa.length > wb.length ? wa.length : wb.length);
  }
}
