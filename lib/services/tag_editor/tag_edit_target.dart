import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/local_backend.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/tag_editor/audio_tags.dart';
import 'package:diapason/services/tag_editor/server_tag_mapping.dart';
import 'package:diapason/services/tag_editor/tag_file.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

sealed class CoverChange {
  const CoverChange();
}

class CoverUnchanged extends CoverChange {
  const CoverUnchanged();
}

class CoverRemoved extends CoverChange {
  const CoverRemoved();
}

class CoverReplaced extends CoverChange {
  CoverReplaced(this.bytes) : mimeType = TagPicture.sniffMimeType(bytes);
  final Uint8List bytes;
  final String mimeType;
}

/// Where edits end up, shown to the user so they know what "save" does.
enum TagStorage { file, jellyfin, plex, none }

/// Why an item can't be edited.
enum TagReadOnlyReason { subsonic, mpd, youtube, unsupportedFile, missingFile, notLoaded }

/// One editable item (a track, or the album item of a server).
abstract class TagEditTarget {
  TagEditTarget(this.item);

  final BaseItemDto item;

  TagStorage get storage;
  Set<TagField> get editableFields;
  bool get canReplaceCover => false;
  bool get canRemoveCover => false;
  TagReadOnlyReason? get readOnlyReason => null;

  /// Local file, when there is one (AcoustID fingerprinting).
  File? get localFile => null;

  /// Duration used for match scoring.
  Duration? get duration => item.runTimeTicksDuration();

  /// Cover shown in the editor when the tags carry none (server images).
  Uri? currentCoverUrl;

  Future<AudioTags> load();

  /// Applies [fields] of [tags] and the [cover] change.
  Future<void> save(AudioTags tags, Set<TagField> fields, CoverChange cover);
}

class LocalFileTarget extends TagEditTarget {
  LocalFileTarget(super.item, this.file);

  final File file;

  @override
  File get localFile => file;

  @override
  TagStorage get storage => TagStorage.file;

  bool get _supported => TagFile.supportedExtensions.contains(p.extension(file.path).toLowerCase());

  @override
  Set<TagField> get editableFields => _supported ? TagField.values.toSet() : const {};

  @override
  bool get canReplaceCover => _supported;

  @override
  bool get canRemoveCover => _supported;

  @override
  TagReadOnlyReason? get readOnlyReason =>
      !_supported ? TagReadOnlyReason.unsupportedFile : (file.existsSync() ? null : TagReadOnlyReason.missingFile);

  @override
  Future<AudioTags> load() => TagFile.read(file);

  @override
  Future<void> save(AudioTags tags, Set<TagField> fields, CoverChange cover) async {
    // Re-read so values edited elsewhere (or other tracks' per-track values
    // in a batch) aren't clobbered: only [fields] change.
    final current = await TagFile.read(file);
    for (final field in fields) {
      current.set(field, tags.all(field));
    }
    switch (cover) {
      case CoverUnchanged():
        break;
      case CoverRemoved():
        current.pictures = [];
      case CoverReplaced(:final bytes, :final mimeType):
        current.pictures = [
          TagPicture(data: bytes, mimeType: mimeType),
          ...current.pictures.where((p) => p.type != PictureType.frontCover),
        ];
    }
    await TagFile.write(file, current);
  }

  /// Rescans the owning local source so the library shows the new values.
  static Future<void> refresh(LocalBackend backend) => backend.scan();
}

/// Jellyfin: `POST /Items/{id}` replaces the item, so the full item JSON is
/// fetched, edited and sent back. Changes live in Jellyfin's database (and
/// its NFO/metadata savers if the admin enabled them), not in the files.
class JellyfinTarget extends TagEditTarget {
  JellyfinTarget(super.item, {this.config, this.isAlbum = false, http.Client? client})
    : _http = client ?? http.Client();

  /// The item's source; when absent the signed-in Jellyfin user is used.
  final MediaSourceConfig? config;
  final bool isAlbum;
  final http.Client _http;
  Map<String, dynamic>? _json;

  @override
  TagStorage get storage => TagStorage.jellyfin;

  @override
  Set<TagField> get editableFields => isAlbum ? JellyfinTagMapping.albumFields : JellyfinTagMapping.trackFields;

  // Images are metadata: Jellyfin only accepts these from administrators;
  // a refusal surfaces as an error on save.
  @override
  bool get canReplaceCover => true;

  @override
  bool get canRemoveCover => true;

  FinampUserHelper get _user => GetIt.instance<FinampUserHelper>();

  bool get _useConfig => config != null && config!.baseUrl.isNotEmpty && config!.accessToken.isNotEmpty;

  String get _userId => config != null && config!.userId.isNotEmpty ? config!.userId : _user.currentUser!.id;

  Uri _url(String path) {
    final base = Uri.parse(_useConfig ? config!.baseUrl : _user.currentUser!.baseURL);
    return base.replace(pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), ...path.split("/")]);
  }

  Map<String, String> get _headers =>
      _useConfig ? {"X-Emby-Token": config!.accessToken} : {"Authorization": _user.authorizationHeader};

  String get _id => item.id.nativeId;

  Future<void> _check(http.Response r, String what) async {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    throw HttpException("Jellyfin $what failed: HTTP ${r.statusCode} ${r.body}");
  }

  @override
  Future<AudioTags> load() async {
    final r = await _http.get(_url("Users/$_userId/Items/$_id"), headers: _headers);
    await _check(r, "item lookup");
    _json = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return JellyfinTagMapping.toTags(_json!, isAlbum: isAlbum);
  }

  @override
  Future<void> save(AudioTags tags, Set<TagField> fields, CoverChange cover) async {
    final editable = fields.intersection(editableFields);
    if (editable.isNotEmpty) {
      if (_json == null) await load();
      final json = _json!;
      final body = JellyfinTagMapping.apply(json, tags, editable, isAlbum: isAlbum);
      final r = await _http.post(
        _url("Items/$_id"),
        headers: {..._headers, "Content-Type": "application/json"},
        body: jsonEncode(body),
      );
      await _check(r, "metadata update");
      _json = body;
    }
    switch (cover) {
      case CoverUnchanged():
        break;
      case CoverRemoved():
        await _check(await _http.delete(_url("Items/$_id/Images/Primary"), headers: _headers), "image removal");
      case CoverReplaced(:final bytes, :final mimeType):
        final r = await _http.post(
          _url("Items/$_id/Images/Primary"),
          headers: {..._headers, "Content-Type": mimeType},
          body: base64Encode(bytes),
        );
        await _check(r, "image upload");
    }
  }
}

/// Plex: metadata edits go through `PUT /library/sections/{id}/all` and are
/// locked; they stay in Plex's database. Album-level values live on the album.
class PlexTarget extends TagEditTarget {
  PlexTarget(super.item, this.config, {this.isAlbum = false, http.Client? client}) : _http = client ?? http.Client();

  final MediaSourceConfig config;
  final bool isAlbum;
  final http.Client _http;
  Map<String, dynamic>? _meta;

  @override
  TagStorage get storage => TagStorage.plex;

  @override
  Set<TagField> get editableFields => isAlbum ? PlexTagMapping.albumFields : PlexTagMapping.trackFields;

  @override
  bool get canReplaceCover => isAlbum;

  Uri _url(String path, [Map<String, String> params = const {}]) {
    final base = Uri.parse(config.baseUrl);
    return base.replace(
      pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), ...path.split("/")],
      queryParameters: {...params, "X-Plex-Token": config.accessToken},
    );
  }

  void _check(http.Response r, String what) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    throw HttpException("Plex $what failed: HTTP ${r.statusCode}");
  }

  @override
  Future<AudioTags> load() async {
    final r = await _http.get(_url("library/metadata/${item.id.nativeId}"), headers: {"Accept": "application/json"});
    _check(r, "metadata lookup");
    final container = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)["MediaContainer"] as Map<String, dynamic>;
    _meta = ((container["Metadata"] as List).first as Map).cast<String, dynamic>();
    _meta!.putIfAbsent("librarySectionID", () => container["librarySectionID"]);
    return PlexTagMapping.toTags(_meta!, isAlbum: isAlbum);
  }

  @override
  Future<void> save(AudioTags tags, Set<TagField> fields, CoverChange cover) async {
    if (_meta == null) await load();
    final meta = _meta!;
    final editable = fields.intersection(editableFields);
    if (editable.isNotEmpty) {
      final params = PlexTagMapping.editParams(
        item.id.nativeId,
        tags,
        editable,
        isAlbum: isAlbum,
        previousGenres: PlexTagMapping.toTags(meta, isAlbum: isAlbum).all(TagField.genres),
      );
      _check(await _http.put(_url("library/sections/${meta["librarySectionID"]}/all", params)), "metadata update");
    }
    if (cover case CoverReplaced(:final bytes)) {
      _check(await _http.post(_url("library/metadata/${item.id.nativeId}/posters"), body: bytes), "poster upload");
    }
  }
}

/// Sources without a tag-writing API: values are shown, nothing is saved.
class ReadOnlyTarget extends TagEditTarget {
  ReadOnlyTarget(super.item, this.reason);

  final TagReadOnlyReason reason;

  @override
  TagStorage get storage => TagStorage.none;

  @override
  Set<TagField> get editableFields => const {};

  @override
  TagReadOnlyReason get readOnlyReason => reason;

  @override
  Future<AudioTags> load() async => tagsFromItem(item);

  @override
  Future<void> save(AudioTags tags, Set<TagField> fields, CoverChange cover) async {}

  static AudioTags tagsFromItem(BaseItemDto item) {
    final isAlbum = item.type == "MusicAlbum";
    final tags = AudioTags();
    tags.setOne(isAlbum ? TagField.album : TagField.title, item.name);
    if (!isAlbum) {
      tags.set(TagField.artists, item.artists ?? const []);
      tags.setOne(TagField.album, item.album);
    }
    tags.set(TagField.albumArtists, item.albumArtists?.map((a) => a.name).nonNulls.toList() ?? [?item.albumArtist]);
    tags.setNumber(TagField.trackNumber, item.indexNumber);
    tags.setNumber(TagField.discNumber, item.parentIndexNumber);
    final premiere = item.premiereDate;
    tags.setOne(
      TagField.date,
      premiere != null && premiere.length >= 10 ? premiere.substring(0, 10) : item.productionYear?.toString(),
    );
    tags.set(TagField.genres, item.genres ?? const []);
    tags.setOne(TagField.comment, item.overview);
    return tags;
  }
}
