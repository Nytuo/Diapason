import 'package:diapason/models/finamp_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

enum DesktopNav {
  home(TablerIcons.home, "Home", null),
  albums(TablerIcons.disc, "Albums", ContentType.albums),
  artists(TablerIcons.users, "Artists", ContentType.performingArtists),
  songs(TablerIcons.music, "Songs", ContentType.tracks),
  genres(TablerIcons.tags, "Genres", ContentType.genres),
  playlists(TablerIcons.playlist, "Playlists", ContentType.playlists),
  smart(TablerIcons.bolt, "Smart", null),
  discover(TablerIcons.compass, "Discover", ContentType.discover),
  youtube(TablerIcons.brand_youtube, "YouTube", null),
  folders(TablerIcons.folder, "Folders", null),
  queue(TablerIcons.list_numbers, "Queue", null);

  const DesktopNav(this.icon, this.label, this.contentType);

  final IconData icon;
  final String label;
  final ContentType? contentType;
}
