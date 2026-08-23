// Reads chapters embedded directly in an audio file, for backends with no
// chapters API of their own (Navidrome/Subsonic, Plex, local files) --
// unlike Jellyfin, which returns chapters via its API and never needs this.
//
// Tries, in order: ID3v2 CHAP frames (MP3, or any format with a prepended
// ID3v2 tag), FLAC/Ogg (Vorbis/Opus) CHAPTERxxx comment fields, and M4A/MP4
// `chpl` atoms -- for local files, via the full-random-access parser; for
// URLs, a best-effort leading-bytes-only attempt that only finds chapters
// when the encoder put `moov` up front ("faststart"). See
// m4a_chapter_parser.dart for why URLs can't do better than best-effort.

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../models/jellyfin_models.dart' as jellyfin_models;
import 'id3_chapter_parser.dart';
import 'm4a_chapter_parser.dart';
import 'vorbis_comment_chapter_parser.dart';

final _log = Logger("EmbeddedChapterParser");

/// Chapters are plain text and, for every format handled here, guaranteed to
/// appear before any audio data (and before any embedded cover art in the
/// common case), so a single generously-sized leading read/fetch is enough
/// without needing multiple round trips.
const int _maxLeadingBytes = 2 * 1024 * 1024;

Future<List<jellyfin_models.ChapterInfo>> parseEmbeddedChaptersFromFile(File file) async {
  try {
    final bytes = await _leadingBytesFromFile(file, _maxLeadingBytes);
    _log.info("Read ${bytes.length} leading bytes from '${file.path}' for chapters");
    final fromTags = _tryTagFormats(bytes);
    if (fromTags.isNotEmpty) {
      _log.info("Found ${fromTags.length} chapter(s) in tags for '${file.path}'");
      return fromTags;
    }
    final m4aChapters = await parseM4aChaptersFromFile(file);
    _log.info("Found ${m4aChapters.length} M4A chapter(s) for '${file.path}'");
    return m4aChapters;
  } catch (e) {
    _log.warning("Failed to read '${file.path}' for embedded chapters: $e");
    return const [];
  }
}

Future<List<jellyfin_models.ChapterInfo>> parseEmbeddedChaptersFromUrl(
  Uri url, {
  Map<String, String> headers = const {},
}) async {
  try {
    final bytes = await _leadingBytesFromUrl(url, headers, _maxLeadingBytes);
    if (bytes == null) {
      _log.warning("No usable response fetching '$url' for chapters");
      return const [];
    }
    _log.info("Fetched ${bytes.length} leading bytes from '$url' for chapters (signature: ${_signature(bytes)})");
    final fromTags = _tryTagFormats(bytes);
    if (fromTags.isNotEmpty) {
      _log.info("Found ${fromTags.length} chapter(s) in tags for '$url'");
      return fromTags;
    }
    final m4aChapters = tryParseM4aBytes(bytes) ?? const [];
    _log.info("Found ${m4aChapters.length} M4A chapter(s) for '$url'");
    return m4aChapters;
  } catch (e) {
    _log.warning("Failed to fetch '$url' for embedded chapters: $e");
    return const [];
  }
}

String _signature(Uint8List bytes) {
  final len = bytes.length < 4 ? bytes.length : 4;
  return bytes.take(len).map((b) => b >= 0x20 && b < 0x7F ? String.fromCharCode(b) : ".").join();
}

List<jellyfin_models.ChapterInfo> _tryTagFormats(Uint8List bytes) =>
    tryParseId3Bytes(bytes) ?? tryParseFlacBytes(bytes) ?? tryParseOggBytes(bytes) ?? const [];

Future<Uint8List> _leadingBytesFromFile(File file, int maxBytes) async {
  final raf = await file.open();
  try {
    return Uint8List.fromList(await raf.read(maxBytes));
  } finally {
    await raf.close();
  }
}

Future<Uint8List?> _leadingBytesFromUrl(Uri url, Map<String, String> headers, int maxBytes) async {
  final client = http.Client();
  try {
    final request = http.Request("GET", url)..headers.addAll({...headers, "Range": "bytes=0-${maxBytes - 1}"});
    final response = await client.send(request);
    _log.info("Range request to '$url' returned HTTP ${response.statusCode}");
    // Some servers ignore Range and stream back the full file (200) instead
    // of a partial response (206); either way the body starts at byte 0, but
    // we must cap how much we read ourselves rather than buffering it all --
    // a lossless FLAC album track can be tens of megabytes.
    if (response.statusCode != 200 && response.statusCode != 206) return null;
    final builder = BytesBuilder();
    await for (final chunk in response.stream) {
      builder.add(chunk);
      if (builder.length >= maxBytes) break;
    }
    final bytes = builder.toBytes();
    return bytes.length > maxBytes ? Uint8List.sublistView(bytes, 0, maxBytes) : bytes;
  } finally {
    client.close();
  }
}
