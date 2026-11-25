import 'package:diapason/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Stands in for a feature the browser can't support (downloads and other file-system work, local network discovery,
/// Diapason Connect, casting, yt-dlp...), so reaching it on the web shows a clear message instead of failing.
class WebUnavailableScreen extends StatelessWidget {
  const WebUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(), body: const WebUnavailableMessage());
  }
}

/// The message of [WebUnavailableScreen], for places that are a tab or a section rather than a whole screen.
class WebUnavailableMessage extends StatelessWidget {
  const WebUnavailableMessage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(TablerIcons.world_off, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.webFeatureUnavailable,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context)!.webFeatureUnavailableDetails,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Route builder that shows [WebUnavailableScreen] instead of [builder]'s screen in a browser.
WidgetBuilder nativeOnlyRoute(WidgetBuilder builder) => kIsWeb ? (_) => const WebUnavailableScreen() : builder;
