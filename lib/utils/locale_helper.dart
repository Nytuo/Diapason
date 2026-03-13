import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/widgets.dart';

String? getLocaleString() {
  final locale = FinampSettingsHelper.finampSettings.locale;
  return locale != null
      ? (locale.countryCode != null
            ? "${locale.languageCode.toLowerCase()}_${locale.countryCode?.toUpperCase()}"
            : locale.toString())
      : null;
}

String getStringComponentsInLocaleOrder(BuildContext context, List<String> components, {String separator = ' '}) {
  final isLeftToRight = Directionality.of(context) == TextDirection.ltr;
  return isLeftToRight ? components.join(separator) : components.reversed.join(separator);
}
