import 'dart:typed_data';

import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/match/acoustid.dart';
import 'package:diapason/services/tag_editor/match/cover_search.dart';
import 'package:diapason/services/tag_editor/match/lookup_http.dart';
import 'package:diapason/services/tag_editor/match/musicbrainz.dart';
import 'package:diapason/services/tag_editor/tag_edit_session.dart';

/// Connects the lookups to a [TagEditSession].
class TagMatcher {
  TagMatcher(this.session, {LookupHttp? http})
    : _http = http ?? _shared,
      musicBrainz = MusicBrainzClient(http ?? _shared),
      covers = CoverSearch(http ?? _shared),
      acoustId = AcoustIdClient(http ?? _shared);

  /// One instance app-wide so the MusicBrainz 1 req/s spacing holds across editors.
  static final _shared = LookupHttp();

  final TagEditSession session;
  final LookupHttp _http;
  final MusicBrainzClient musicBrainz;
  final CoverSearch covers;
  final AcoustIdClient acoustId;

  MatchQuery queryFor(int track) =>
      MatchQuery.fromTags(session.edited[track], duration: session.tracks[track].duration);

  Future<List<MbRecordingCandidate>> searchRecordings(int track, {String? title, String? artist}) {
    final base = queryFor(track);
    return musicBrainz.searchRecordings(
      MatchQuery(
        title: title ?? base.title,
        artists: artist != null ? [artist] : base.artists,
        album: base.album,
        duration: base.duration,
      ),
    );
  }

  Future<List<MbReleaseCandidate>> searchReleases({String? album, String? artist}) {
    final first = session.edited.isEmpty ? AudioTags() : session.edited.first;
    final tags = session.albumEdited ?? first;
    return musicBrainz.searchReleases(
      MatchQuery(
        album: album ?? tags[TagField.album] ?? first[TagField.album],
        albumArtists: artist != null ? [artist] : tags.all(TagField.albumArtists),
        artists: first.all(TagField.artists),
      ),
      trackCount: session.tracks.length,
      year: int.tryParse((first[TagField.date] ?? "").split("-").first),
    );
  }

  /// Applies [candidate] to [track]: looks up its best release to fill album
  /// fields and the release-track id; falls back to recording-only fields.
  Future<void> applyRecording(int track, MbRecordingCandidate candidate, {bool includeGenres = false}) async {
    final releaseId = candidate.bestRelease?.id;
    final release = releaseId == null ? null : await musicBrainz.lookupRelease(releaseId);
    final mbTrack = release?.tracks.where((t) => t.recordingId == candidate.id).firstOrNull;
    final copy = session.edited[track].copy();
    if (release != null && mbTrack != null) {
      release.applyTrack(copy, mbTrack, includeGenres: includeGenres);
    } else {
      copy.setOne(TagField.title, candidate.title);
      copy.set(TagField.artists, candidate.artists.map((a) => a.name).toList());
      copy.set(TagField.musicBrainzArtistIds, candidate.artists.map((a) => a.id).nonNulls.toList());
      copy.setOne(TagField.musicBrainzRecordingId, candidate.id);
    }
    session.applyToTrack(track, copy);
    if (session.albumEdited != null && release != null) {
      release.applyAlbumFields(session.albumEdited!, includeGenres: includeGenres);
    }
  }

  /// Returns how many tracks were paired with the release.
  Future<int?> applyRelease(MbReleaseCandidate candidate, {bool includeGenres = false}) async {
    final release = await musicBrainz.lookupRelease(candidate.id);
    if (release == null) return null;
    return session.applyRelease(release, includeGenres: includeGenres);
  }

  /// AcoustID → MusicBrainz recordings for [track] (desktop, fpcalc, API key).
  Future<List<MbRecordingCandidate>> fingerprint(int track, String apiKey) async {
    final file = session.tracks[track].localFile;
    if (file == null) return const [];
    final matches = await acoustId.lookup(file, apiKey);
    final query = queryFor(track);
    final results = <MbRecordingCandidate>[];
    for (final match in matches.take(3)) {
      for (final id in match.recordingIds.take(3)) {
        final recording = await musicBrainz.lookupRecording(id, query);
        if (recording == null) continue;
        // The fingerprint is stronger evidence than tag similarity.
        recording.confidence = (recording.confidence + match.score) / 2;
        results.add(recording);
      }
    }
    return results..sort((a, b) => b.confidence.compareTo(a.confidence));
  }

  Future<List<CoverCandidate>> searchCovers({String? album, String? artist}) {
    final tags = session.albumEdited ?? (session.edited.isEmpty ? AudioTags() : session.edited.first);
    final first = session.edited.isEmpty ? AudioTags() : session.edited.first;
    return covers.search(
      album: album ?? tags[TagField.album] ?? first[TagField.album],
      artist: artist ?? tags.all(TagField.albumArtists).firstOrNull ?? first.all(TagField.artists).firstOrNull,
      releaseId: first[TagField.musicBrainzReleaseId],
      releaseGroupId: first[TagField.musicBrainzReleaseGroupId],
    );
  }

  Future<Uint8List> download(Uri url) async => Uint8List.fromList(await _http.getBytes(url));
}
