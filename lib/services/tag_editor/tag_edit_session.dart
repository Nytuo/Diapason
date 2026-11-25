import 'dart:io';

import 'package:collection/collection.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/backends/local_backend.dart';
import 'package:diapason/services/backends/media_backend.dart';
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/match/musicbrainz.dart';
import 'package:diapason/services/tag_editor/tag_edit_target.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Editor state for one track or an album batch: the loaded values, the
/// user's edits and the save logic. UI-agnostic so it can be tested.
class TagEditSession extends ChangeNotifier {
  TagEditSession({required this.item, required this.tracks, this.albumTarget, this.localBackend});

  static final _log = Logger("TagEditor");

  /// The item the editor was opened on (track or album).
  final BaseItemDto item;
  final List<TagEditTarget> tracks;

  /// Server album item carrying album-level values (Jellyfin, Plex).
  final TagEditTarget? albumTarget;

  /// Rescanned after saving local files.
  final LocalBackend? localBackend;

  bool get isAlbum => item.type == "MusicAlbum";

  final List<AudioTags> _original = [];
  final List<AudioTags> edited = [];
  AudioTags? _albumOriginal;
  AudioTags? albumEdited;
  final Map<int, Object> loadErrors = {};

  CoverChange cover = const CoverUnchanged();

  /// Builds the targets for [item] from its source.
  static Future<TagEditSession> open(BaseItemDto item) async {
    final backend = GetIt.instance<BackendRegistry>().forItem(item);
    final isAlbum = item.type == "MusicAlbum";
    final trackItems = isAlbum
        ? await backend?.getItems(parentItem: item, includeItemTypes: "Audio") ?? const <BaseItemDto>[]
        : [item];
    final sorted = trackItems.sortedBy<num>((t) => (t.parentIndexNumber ?? 1) * 10000 + (t.indexNumber ?? 0));
    final kind = backend?.config.kind;

    TagEditTarget trackTarget(BaseItemDto t) => switch (kind) {
      MediaSourceKind.local => () {
        final path = (backend! as LocalBackend).pathFor(t.id);
        return path == null ? ReadOnlyTarget(t, TagReadOnlyReason.missingFile) : LocalFileTarget(t, File(path));
      }(),
      MediaSourceKind.jellyfin => JellyfinTarget(t, config: backend!.config),
      MediaSourceKind.plex => PlexTarget(t, backend!.config),
      MediaSourceKind.subsonic => ReadOnlyTarget(t, TagReadOnlyReason.subsonic),
      MediaSourceKind.mpd => ReadOnlyTarget(t, TagReadOnlyReason.mpd),
      _ => ReadOnlyTarget(t, TagReadOnlyReason.youtube),
    };

    final albumTarget = !isAlbum
        ? null
        : switch (kind) {
            MediaSourceKind.jellyfin => JellyfinTarget(item, config: backend!.config, isAlbum: true),
            MediaSourceKind.plex => PlexTarget(item, backend!.config, isAlbum: true),
            _ => null,
          };
    final session = TagEditSession(
      item: item,
      tracks: sorted.map(trackTarget).toList(),
      albumTarget: albumTarget,
      localBackend: backend is LocalBackend ? backend : null,
    );
    final coverUrl = backend?.imageUrl(item, maxWidth: 600, maxHeight: 600);
    for (final t in [...session.tracks, ?albumTarget]) {
      t.currentCoverUrl = coverUrl ?? _imageUrl(backend, t.item);
    }
    await session.load();
    return session;
  }

  static Uri? _imageUrl(MediaBackend? backend, BaseItemDto item) =>
      backend?.imageUrl(item, maxWidth: 600, maxHeight: 600);

  Future<void> load() async {
    _original.clear();
    edited.clear();
    loadErrors.clear();
    for (var i = 0; i < tracks.length; i++) {
      AudioTags tags;
      try {
        tags = await tracks[i].load();
      } catch (e, st) {
        _log.warning("Couldn't read tags of ${tracks[i].item.name}", e, st);
        loadErrors[i] = e;
        tags = ReadOnlyTarget.tagsFromItem(tracks[i].item);
      }
      _original.add(tags);
      edited.add(tags.copy());
    }
    if (albumTarget != null) {
      try {
        _albumOriginal = await albumTarget!.load();
      } catch (e, st) {
        _log.warning("Couldn't read album metadata", e, st);
        _albumOriginal = ReadOnlyTarget.tagsFromItem(item);
      }
      albumEdited = _albumOriginal!.copy();
    }
    notifyListeners();
  }

  bool _trackEditable(int i, TagField field) => !loadErrors.containsKey(i) && tracks[i].editableFields.contains(field);

  bool canEdit(TagField field, {int? track}) {
    if (track != null) return _trackEditable(track, field);
    return Iterable<int>.generate(tracks.length).any((i) => _trackEditable(i, field)) ||
        (albumTarget?.editableFields.contains(field) ?? false);
  }

  bool get canEditAnything => TagField.values.any((f) => canEdit(f)) || canReplaceCover;

  /// The first reason a track can't be edited, for the banner.
  TagReadOnlyReason? get readOnlyReason {
    if (loadErrors.isNotEmpty && tracks.length == 1) return TagReadOnlyReason.notLoaded;
    return tracks.map((t) => t.readOnlyReason).nonNulls.firstOrNull;
  }

  TagStorage get storage => tracks.firstOrNull?.storage ?? TagStorage.none;

  bool get canReplaceCover => (albumTarget ?? tracks.firstOrNull)?.canReplaceCover ?? false;

  bool get canRemoveCover => (albumTarget ?? tracks.firstOrNull)?.canRemoveCover ?? false;

  /// Shared value across tracks (and the album item), or null when they differ.
  List<String>? shared(TagField field) {
    final all = [...edited, ?(albumTarget?.editableFields.contains(field) ?? false ? albumEdited : null)];
    if (all.isEmpty) return const [];
    final first = all.first.all(field);
    return all.every((t) => const ListEquality<String>().equals(t.all(field), first)) ? first : null;
  }

  void setShared(TagField field, List<String> values) {
    for (var i = 0; i < edited.length; i++) {
      if (_trackEditable(i, field)) edited[i].set(field, values);
    }
    if (albumTarget?.editableFields.contains(field) ?? false) albumEdited?.set(field, values);
    notifyListeners();
  }

  void setTrack(int i, TagField field, List<String> values) {
    if (!_trackEditable(i, field)) return;
    edited[i].set(field, values);
    notifyListeners();
  }

  void setCover(CoverChange change) {
    cover = change;
    notifyListeners();
  }

  /// Picture embedded in the (first) track, for the preview.
  TagPicture? get embeddedCover => switch (cover) {
    CoverReplaced(:final bytes, :final mimeType) => TagPicture(data: bytes, mimeType: mimeType),
    CoverRemoved() => null,
    CoverUnchanged() => edited.firstOrNull?.frontCover,
  };

  Uri? get serverCoverUrl => (albumTarget ?? tracks.firstOrNull)?.currentCoverUrl;

  Set<TagField> changedFields(int i) =>
      TagField.values.where((f) => _trackEditable(i, f) && !_original[i].sameValue(edited[i], f)).toSet();

  Set<TagField> get _albumChanged => albumTarget == null || albumEdited == null
      ? const {}
      : albumTarget!.editableFields.where((f) => !_albumOriginal!.sameValue(albumEdited!, f)).toSet();

  bool get hasChanges =>
      cover is! CoverUnchanged ||
      _albumChanged.isNotEmpty ||
      Iterable<int>.generate(edited.length).any((i) => changedFields(i).isNotEmpty);

  /// Copies [matched]'s values for every editable field of track [i].
  void applyToTrack(int i, AudioTags matched, {Iterable<TagField>? only}) {
    for (final field in only ?? TagField.values) {
      if (_trackEditable(i, field)) edited[i].set(field, matched.all(field));
    }
    notifyListeners();
  }

  /// Applies a looked-up release: album fields everywhere, track fields to
  /// the tracks [MbRelease.mapTracks] could pair. Returns how many matched.
  int applyRelease(MbRelease release, {bool includeGenres = false}) {
    final mapped = release.mapTracks([
      for (var i = 0; i < edited.length; i++)
        (
          title: edited[i][TagField.title],
          disc: edited[i].number(TagField.discNumber),
          track: edited[i].number(TagField.trackNumber),
          duration: tracks[i].duration,
        ),
    ]);
    for (var i = 0; i < edited.length; i++) {
      final copy = edited[i].copy();
      final track = mapped[i];
      if (track == null) {
        release.applyAlbumFields(copy, includeGenres: includeGenres);
      } else {
        release.applyTrack(copy, track, includeGenres: includeGenres);
      }
      applyToTrack(i, copy);
    }
    if (albumEdited != null) {
      release.applyAlbumFields(albumEdited!, includeGenres: includeGenres);
    }
    notifyListeners();
    return mapped.nonNulls.length;
  }

  /// Saves every change. Returns the errors per item name (empty = success).
  Future<Map<String, Object>> save() async {
    final errors = <String, Object>{};
    final albumHandlesCover = albumTarget?.canReplaceCover ?? false;
    for (var i = 0; i < tracks.length; i++) {
      final fields = changedFields(i);
      final trackCover = albumHandlesCover ? const CoverUnchanged() : cover;
      if (fields.isEmpty && trackCover is CoverUnchanged) continue;
      try {
        await tracks[i].save(edited[i], fields, trackCover);
      } catch (e, st) {
        _log.severe("Saving tags of ${tracks[i].item.name} failed", e, st);
        errors[tracks[i].item.name ?? "?"] = e;
      }
    }
    if (albumTarget != null && (_albumChanged.isNotEmpty || (albumHandlesCover && cover is! CoverUnchanged))) {
      try {
        await albumTarget!.save(albumEdited!, _albumChanged, albumHandlesCover ? cover : const CoverUnchanged());
      } catch (e, st) {
        _log.severe("Saving album metadata failed", e, st);
        errors[item.name ?? "?"] = e;
      }
    }
    if (localBackend != null) await localBackend!.scan();
    if (errors.isEmpty) {
      cover = const CoverUnchanged();
      // Re-read what was actually stored.
      await load();
    }
    notifyListeners();
    return errors;
  }
}
