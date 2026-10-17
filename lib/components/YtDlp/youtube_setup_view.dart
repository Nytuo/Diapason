import 'package:diapason/components/YtDlp/ytdlp_install_dialog.dart';
import 'package:diapason/screens/uploader_settings_screen.dart';
import 'package:diapason/screens/ytdlp_settings_screen.dart';
import 'package:diapason/services/youtube/local_ytdlp_service.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Shown in place of YouTube content when no yt-dlp route works, explaining
/// why in plain words and offering the way to fix it.
class YouTubeSetupView extends StatelessWidget {
  const YouTubeSetupView({super.key});

  @override
  Widget build(BuildContext context) {
    final availability = GetIt.instance<YouTubeAvailability>();
    return ValueListenableBuilder<YouTubeStatus>(
      valueListenable: availability.status,
      builder: (context, status, _) {
        final theme = Theme.of(context);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(TablerIcons.brand_youtube, size: 48, color: theme.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text("YouTube isn't set up yet", style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final problem in status.problems)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(problem, textAlign: TextAlign.center),
                    ),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (LocalYtDlpService.supported)
                        FilledButton.icon(
                          onPressed: () async {
                            final installed = await showYtDlpInstallDialog(context);
                            if (installed) await availability.refresh();
                          },
                          icon: const Icon(TablerIcons.download),
                          label: const Text("Set up yt-dlp here"),
                        ),
                      if (LocalYtDlpService.supported)
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pushNamed(YtDlpSettingsScreen.routeName),
                          child: const Text("yt-dlp settings"),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).pushNamed(UploaderSettingsScreen.routeName),
                        icon: const Icon(TablerIcons.cloud_upload),
                        label: const Text("Use an uploader"),
                      ),
                    ],
                  ),
                  TextButton(onPressed: availability.refresh, child: const Text("Check again")),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

bool _offeredThisSession = false;

/// Forgets that the offer was made, so a test can see it again. The app never calls this.
@visibleForTesting
void resetYtDlpSetupOffer() => _offeredThisSession = false;

/// Desktop only: on launch, if YouTube can't work, offer once to set up yt-dlp.
Future<void> offerYtDlpSetupIfNeeded(BuildContext context) async {
  if (!LocalYtDlpService.supported || _offeredThisSession) return;
  final local = GetIt.instance<LocalYtDlpService>();
  final availability = GetIt.instance<YouTubeAvailability>();
  for (var i = 0; i < 20 && local.status.value.state == LocalYtDlpState.checking; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  await availability.refresh();
  if (!context.mounted) return;
  if (availability.status.value.available) return;
  if (local.config.value.promptDismissed) return;
  if (availability.status.value.uploaderWanted) return;
  if (_offeredThisSession) return;
  _offeredThisSession = true;
  final installed = await showYtDlpInstallDialog(context);
  if (installed) await availability.refresh();
}
