import 'package:flutter/material.dart';
import 'package:diapason/l10n/app_localizations.dart';

String processArtist(String? artist, BuildContext context) {
  if (artist == null) {
    return AppLocalizations.of(context)!.unknownArtist;
  } else {
    return artist;
  }
}
