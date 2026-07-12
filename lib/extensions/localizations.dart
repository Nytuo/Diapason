import 'package:diapason/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';

extension LocalizationFromContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}
