import 'package:diapason/services/tag_editor/audio_tags.dart';

/// Pure conversions between server metadata JSON and [AudioTags], kept free
/// of networking so they can be tested.

abstract final class JellyfinTagMapping {
  static const providerKeys = {
    TagField.musicBrainzRecordingId: "MusicBrainzRecording",
    TagField.musicBrainzReleaseTrackId: "MusicBrainzTrack",
    TagField.musicBrainzReleaseId: "MusicBrainzAlbum",
    TagField.musicBrainzReleaseGroupId: "MusicBrainzReleaseGroup",
    TagField.musicBrainzArtistIds: "MusicBrainzArtist",
    TagField.musicBrainzAlbumArtistIds: "MusicBrainzAlbumArtist",
  };

  /// Fields `POST /Items/{id}` can change on an audio track. Totals, lyrics
  /// and ReplayGain have no counterpart in Jellyfin's item model.
  static const trackFields = {
    TagField.title,
    TagField.artists,
    TagField.albumArtists,
    TagField.album,
    TagField.trackNumber,
    TagField.discNumber,
    TagField.date,
    TagField.genres,
    TagField.composers,
    TagField.comment,
    TagField.musicBrainzRecordingId,
    TagField.musicBrainzReleaseTrackId,
    TagField.musicBrainzReleaseId,
    TagField.musicBrainzReleaseGroupId,
    TagField.musicBrainzArtistIds,
    TagField.musicBrainzAlbumArtistIds,
  };

  /// Fields that also live on the MusicAlbum item.
  static const albumFields = {
    TagField.album,
    TagField.albumArtists,
    TagField.date,
    TagField.genres,
    TagField.musicBrainzReleaseId,
    TagField.musicBrainzReleaseGroupId,
    TagField.musicBrainzAlbumArtistIds,
  };

  static List<String> _names(dynamic list) => [
    for (final e in (list as List? ?? const []))
      if (e is Map && e["Name"] is String) e["Name"] as String else if (e is String) e,
  ];

  static AudioTags toTags(Map<String, dynamic> json, {bool isAlbum = false}) {
    final tags = AudioTags();
    tags.setOne(isAlbum ? TagField.album : TagField.title, json["Name"] as String?);
    if (!isAlbum) {
      tags.set(
        TagField.artists,
        _names(json["Artists"]).isNotEmpty ? _names(json["Artists"]) : _names(json["ArtistItems"]),
      );
      tags.setOne(TagField.album, json["Album"] as String?);
      tags.setNumber(TagField.trackNumber, json["IndexNumber"] as int?);
      tags.setNumber(TagField.discNumber, json["ParentIndexNumber"] as int?);
      tags.set(TagField.composers, [
        for (final p in (json["People"] as List? ?? const []).cast<Map<String, dynamic>>())
          if (p["Type"] == "Composer" && p["Name"] is String) p["Name"] as String,
      ]);
    }
    tags.set(TagField.albumArtists, _names(json["AlbumArtists"]));
    final premiere = json["PremiereDate"] as String?;
    tags.setOne(
      TagField.date,
      premiere != null && premiere.length >= 10
          ? premiere.substring(0, 10)
          : (json["ProductionYear"] as int?)?.toString(),
    );
    tags.set(TagField.genres, (json["Genres"] as List? ?? const []).cast<String>());
    tags.setOne(TagField.comment, json["Overview"] as String?);
    final ids = (json["ProviderIds"] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final MapEntry(key: field, value: key) in providerKeys.entries) {
      final value = ids.entries.where((e) => e.key.toLowerCase() == key.toLowerCase()).firstOrNull?.value as String?;
      tags.set(field, field.isMultiValue ? (value ?? "").split(RegExp(r"[/;]")) : [value ?? ""]);
    }
    return tags;
  }

  /// Writes [fields] of [tags] into a full item JSON as returned by
  /// `GET /Users/{user}/Items/{id}` (everything else is sent back unchanged,
  /// since the endpoint replaces the whole item).
  static Map<String, dynamic> apply(
    Map<String, dynamic> json,
    AudioTags tags,
    Set<TagField> fields, {
    bool isAlbum = false,
  }) {
    final out = Map<String, dynamic>.of(json);
    for (final field in fields) {
      switch (field) {
        case TagField.title when !isAlbum:
          out["Name"] = tags[TagField.title] ?? "";
        case TagField.album:
          if (isAlbum) {
            out["Name"] = tags[TagField.album] ?? "";
          } else {
            out["Album"] = tags[TagField.album];
          }
        case TagField.artists when !isAlbum:
          out["Artists"] = tags.all(TagField.artists);
          out["ArtistItems"] = [
            for (final name in tags.all(TagField.artists)) {"Name": name},
          ];
        case TagField.albumArtists:
          out["AlbumArtists"] = [
            for (final name in tags.all(TagField.albumArtists)) {"Name": name},
          ];
          out["AlbumArtist"] = tags.all(TagField.albumArtists).firstOrNull;
        case TagField.trackNumber when !isAlbum:
          out["IndexNumber"] = tags.number(TagField.trackNumber);
        case TagField.discNumber when !isAlbum:
          out["ParentIndexNumber"] = tags.number(TagField.discNumber);
        case TagField.date:
          final date = tags[TagField.date];
          final year = int.tryParse((date ?? "").split("-").first);
          out["ProductionYear"] = year;
          final full = date == null ? null : DateTime.tryParse(date.length == 4 ? "$date-01-01" : date);
          out["PremiereDate"] = full == null ? null : "${full.toIso8601String().substring(0, 10)}T00:00:00.0000000Z";
        case TagField.genres:
          out["Genres"] = tags.all(TagField.genres);
        case TagField.composers when !isAlbum:
          out["People"] = [
            for (final p in (json["People"] as List? ?? const []).cast<Map<String, dynamic>>())
              if (p["Type"] != "Composer") p,
            for (final name in tags.all(TagField.composers)) {"Name": name, "Type": "Composer"},
          ];
        case TagField.comment:
          out["Overview"] = tags[TagField.comment];
        case _ when providerKeys.containsKey(field):
          final ids = Map<String, dynamic>.of((out["ProviderIds"] as Map?)?.cast<String, dynamic>() ?? const {});
          final key = providerKeys[field]!;
          ids.removeWhere((k, _) => k.toLowerCase() == key.toLowerCase());
          final values = tags.all(field);
          if (values.isNotEmpty) ids[key] = values.join("/");
          out["ProviderIds"] = ids;
        default:
          break;
      }
    }
    return out;
  }
}

abstract final class PlexTagMapping {
  static const trackType = 10;
  static const albumType = 9;

  /// Track-level fields Plex's edit API accepts (`originalTitle` is the
  /// track artist when it differs from the album artist).
  static const trackFields = {TagField.title, TagField.artists, TagField.trackNumber, TagField.discNumber};

  static const albumFields = {TagField.album, TagField.date, TagField.genres, TagField.comment};

  static List<String> _tags(dynamic list) => [
    for (final e in (list as List? ?? const []).cast<Map<String, dynamic>>())
      if (e["tag"] is String) e["tag"] as String,
  ];

  static AudioTags toTags(Map<String, dynamic> m, {bool isAlbum = false}) {
    final tags = AudioTags();
    if (isAlbum) {
      tags.setOne(TagField.album, m["title"] as String?);
      tags.setOne(TagField.albumArtists, m["parentTitle"] as String?);
      final released = m["originallyAvailableAt"] as String?;
      tags.setOne(TagField.date, released ?? (m["year"] as int?)?.toString());
      tags.set(TagField.genres, _tags(m["Genre"]));
      tags.setOne(TagField.comment, m["summary"] as String?);
    } else {
      tags.setOne(TagField.title, m["title"] as String?);
      tags.setOne(TagField.artists, (m["originalTitle"] ?? m["grandparentTitle"]) as String?);
      tags.setOne(TagField.album, m["parentTitle"] as String?);
      tags.setOne(TagField.albumArtists, m["grandparentTitle"] as String?);
      tags.setNumber(TagField.trackNumber, m["index"] as int?);
      tags.setNumber(TagField.discNumber, m["parentIndex"] as int?);
      tags.setOne(TagField.date, (m["parentYear"] ?? m["year"])?.toString());
      tags.set(TagField.genres, _tags(m["Genre"]));
    }
    return tags;
  }

  /// Query parameters for `PUT /library/sections/{section}/all`. Edited
  /// fields are locked so Plex's next refresh doesn't undo them.
  static Map<String, String> editParams(
    String ratingKey,
    AudioTags tags,
    Set<TagField> fields, {
    required bool isAlbum,
    List<String> previousGenres = const [],
  }) {
    final params = <String, String>{"type": "${isAlbum ? albumType : trackType}", "id": ratingKey};
    void value(String name, String? v) {
      params["$name.value"] = v ?? "";
      params["$name.locked"] = "1";
    }

    for (final field in fields) {
      switch (field) {
        case TagField.title when !isAlbum:
          value("title", tags[TagField.title]);
        case TagField.album when isAlbum:
          value("title", tags[TagField.album]);
        case TagField.artists when !isAlbum:
          value("originalTitle", tags.all(TagField.artists).join(", "));
        case TagField.trackNumber when !isAlbum:
          value("index", tags[TagField.trackNumber]);
        case TagField.discNumber when !isAlbum:
          value("parentIndex", tags[TagField.discNumber]);
        case TagField.date when isAlbum:
          final date = tags[TagField.date];
          final parsed = date == null ? null : DateTime.tryParse(date.length == 4 ? "$date-01-01" : date);
          value("originallyAvailableAt", parsed?.toIso8601String().substring(0, 10));
          value("year", parsed?.year.toString());
        case TagField.genres when isAlbum:
          final genres = tags.all(TagField.genres);
          for (var i = 0; i < genres.length; i++) {
            params["genre[$i].tag.tag"] = genres[i];
          }
          final removed = previousGenres.where((g) => !genres.contains(g)).toList();
          if (removed.isNotEmpty) params["genre[].tag.tag-"] = removed.map(Uri.encodeComponent).join(",");
          params["genre.locked"] = "1";
        case TagField.comment when isAlbum:
          value("summary", tags[TagField.comment]);
        default:
          break;
      }
    }
    return params;
  }
}
