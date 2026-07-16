import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/components/finamp_icon.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/client_certificate_authentication_menu.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/screens/accessibility_settings_screen.dart';
import 'package:diapason/screens/audio_service_settings_screen.dart';
import 'package:diapason/screens/downloads_settings_screen.dart';
import 'package:diapason/screens/home_screen_settings_screen.dart';
import 'package:diapason/screens/cache_settings_screen.dart';
import 'package:diapason/screens/connect_screen.dart';
import 'package:diapason/screens/cast_screen.dart';
import 'package:diapason/screens/import_screen.dart';
import 'package:diapason/screens/radio_screen.dart';
import 'package:diapason/screens/shortcuts_screen.dart';
import 'package:diapason/screens/ipod/ipod_controller.dart';
import 'package:diapason/screens/ipod/ipod_shell.dart';
import 'package:diapason/screens/wrapped_screen.dart';
import 'package:diapason/screens/scrobbling_settings_screen.dart';
import 'package:diapason/screens/uploader_settings_screen.dart';
import 'package:diapason/screens/sources_settings_screen.dart';
import 'package:diapason/screens/interaction_settings_screen.dart';
import 'package:diapason/screens/language_selection_screen.dart';
import 'package:diapason/screens/layout_settings_screen.dart';
import 'package:diapason/screens/network_settings_screen.dart';
import 'package:diapason/screens/playback_reporting_settings_screen.dart';
import 'package:diapason/screens/transcoding_settings_screen.dart';
import 'package:diapason/screens/view_selector.dart';
import 'package:diapason/screens/visualizer_settings_screen.dart';
import 'package:diapason/screens/volume_normalization_settings_screen.dart';
import 'package:diapason/services/client_certificate_installer.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/utils/platform_helper.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:locale_names/locale_names.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  static const routeName = "/settings";

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const repoLink = "https://github.com/Nytuo/Diapason";
  static const releaseNotesLink = "https://github.com/Nytuo/Diapason/releases";
  static const translationsLink = "https://hosted.weblate.org/projects/finamp";

  bool get _hasJellyfinSource =>
      GetIt.instance<BackendRegistry>().ofKind(MediaSourceKind.jellyfin).isNotEmpty;

  Widget _sectionHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.settings),
        leading: FinampAppBarBackButton(),
        actions: [
          FinampSettingsHelper.makeSettingsResetButtonWithDialog(
            context,
            FinampSettingsHelper.resetAllSettings,
            isGlobal: true,
          ),
          Semantics.fromProperties(
            properties: SemanticsProperties(label: AppLocalizations.of(context)!.about, button: true),
            excludeSemantics: true,
            container: true,
            child: IconButton(
              icon: const Icon(Icons.info),
              onPressed: () async {
                final localizations = AppLocalizations.of(context)!;
                final applicationLegalese = AppLocalizations.of(context)!.applicationLegalese(repoLink);
                PackageInfo packageInfo = await PackageInfo.fromPlatform();

                ThemeData theme = Theme.of(context);
                const linkStyle = TextStyle(color: Colors.blue, decoration: TextDecoration.underline);

                showAboutDialog(
                  context: context,
                  applicationName: packageInfo.appName,
                  applicationVersion: packageInfo.version,
                  applicationIcon: Padding(padding: const EdgeInsets.only(top: 8.0), child: FinampIcon(56, 56)),
                  applicationLegalese: applicationLegalese,
                  children: [
                    const SizedBox(height: 20),
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: TextStyle(color: theme.textTheme.bodyMedium!.color),
                        children: [
                          TextSpan(
                            text: localizations.finampTagline,
                            style: const TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w500),
                          ),
                          const TextSpan(text: '\n\n'),
                          TextSpan(text: localizations.aboutContributionPrompt),
                          const TextSpan(text: '\n\n'),
                          TextSpan(text: '${localizations.aboutContributionLink}\n'),
                          TextSpan(
                            text: repoLink,
                            style: linkStyle,
                            recognizer: TapGestureRecognizer()
                              ..onTap = () async {
                                await launchUrl(Uri.parse(repoLink));
                              },
                          ),
                          const TextSpan(text: '\n\n'),
                          TextSpan(text: '${localizations.aboutTranslations}\n'),
                          TextSpan(
                            text: translationsLink,
                            style: linkStyle,
                            recognizer: TapGestureRecognizer()
                              ..onTap = () async {
                                await launchUrl(Uri.parse(translationsLink));
                              },
                          ),
                          const TextSpan(text: '\n\n'),
                          TextSpan(text: '${localizations.aboutReleaseNotes}\n'),
                          TextSpan(
                            text: releaseNotesLink,
                            style: linkStyle,
                            recognizer: TapGestureRecognizer()
                              ..onTap = () async {
                                await launchUrl(Uri.parse(releaseNotesLink));
                              },
                          ),
                          const TextSpan(text: '\n\n\n'),
                          TextSpan(
                            text: isDesktop
                                ? "The desktop version of Diapason is an independent build and is not derived from the Finamp fork."
                                : localizations.forkNotice,
                          ),
                          const TextSpan(text: '\n\n\n'),
                          TextSpan(
                            text: localizations.aboutThanks,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          _sectionHeader(context, "Library & sources"),
          ListTile(
            leading: const Icon(TablerIcons.library),
            title: const Text("Sources"),
            subtitle: const Text("Jellyfin, Plex, Subsonic and local files"),
            onTap: () => Navigator.of(context).pushNamed(SourcesSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.file_import),
            title: const Text("Import music"),
            subtitle: const Text("From this device, or the desktop app"),
            onTap: () => Navigator.of(context).pushNamed(ImportScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.cloud_upload),
            title: const Text("Uploader"),
            subtitle: const Text("Add downloaded tracks to your library"),
            onTap: () => Navigator.of(context).pushNamed(UploaderSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(AppLocalizations.of(context)!.downloadSettings),
            onTap: () => Navigator.of(context).pushNamed(DownloadsSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.database),
            title: const Text("Cache"),
            subtitle: const Text("Keep streamed tracks on disk"),
            onTap: () => Navigator.of(context).pushNamed(CacheSettingsScreen.routeName),
          ),

          _sectionHeader(context, "Playback"),
          ListTile(
            leading: const Icon(Icons.music_note),
            title: Text(AppLocalizations.of(context)!.audioService),
            onTap: () => Navigator.of(context).pushNamed(AudioServiceSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.equalizer_rounded),
            title: Text(AppLocalizations.of(context)!.volumeNormalizationSettingsTitle),
            onTap: () => Navigator.of(context).pushNamed(VolumeNormalizationSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.broadcast),
            title: const Text("Scrobbling"),
            subtitle: const Text("Last.fm and ListenBrainz"),
            onTap: () => Navigator.of(context).pushNamed(ScrobblingSettingsScreen.routeName),
          ),
          if (!isDesktop)
            ListTile(
              leading: const Icon(TablerIcons.cast),
              title: const Text("Cast"),
              subtitle: const Text("Send playback to a Chromecast"),
              onTap: () => Navigator.of(context).pushNamed(CastScreen.routeName),
            ),
          ListTile(
            leading: const Icon(TablerIcons.device_speaker),
            title: const Text("Diapason Connect"),
            subtitle: const Text("Control another Diapason device"),
            onTap: () => Navigator.of(context).pushNamed(ConnectScreen.routeName),
          ),

          _sectionHeader(context, "Appearance & home"),
          ListTile(
            leading: const Icon(Icons.widgets),
            title: Text(AppLocalizations.of(context)!.layoutAndTheme),
            onTap: () => Navigator.of(context).pushNamed(LayoutSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.home),
            title: Text(AppLocalizations.of(context)!.homeScreenSettingsTitle),
            onTap: () => Navigator.of(context).pushNamed(HomeScreenSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.pin),
            title: const Text("Pins & searches"),
            subtitle: const Text("What's on your home screen and widget"),
            onTap: () => Navigator.of(context).pushNamed(ShortcutsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.wave_sine),
            title: const Text("Visualizer"),
            subtitle: const Text("Spectrum curve behind the player screen"),
            onTap: () => Navigator.of(context).pushNamed(VisualizerSettingsScreen.routeName),
          ),
          const WrappedTile(),
          if (!isDesktop)
            ListTile(
              leading: const Icon(TablerIcons.player_play),
              title: const Text("iPod Classic mode"),
              subtitle: const Text("Replaces the app with a click-wheel iPod"),
              onTap: () {
                FinampSetters.setInterfaceMode(InterfaceMode.ipod.name);
                Navigator.of(context).pushNamed(IpodShell.routeName);
              },
            ),

          _sectionHeader(context, "System"),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: Text(AppLocalizations.of(context)!.networkSettingsTitle),
            onTap: () => Navigator.of(context).pushNamed(NetworkSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.gesture),
            title: Text(AppLocalizations.of(context)!.interactions),
            onTap: () => Navigator.of(context).pushNamed(InteractionSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.accessible),
            title: Text(AppLocalizations.of(context)!.accessibility),
            onTap: () => Navigator.of(context).pushNamed(AccessibilitySettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(AppLocalizations.of(context)!.language),
            subtitle: Text(
              ref.watch(finampSettingsProvider.locale)?.nativeDisplayLanguage ?? AppLocalizations.of(context)!.system,
            ),
            onTap: () => Navigator.of(context).pushNamed(LanguageSelectionScreen.routeName),
          ),

          if (_hasJellyfinSource) ...[
            _sectionHeader(context, "Jellyfin server"),
            ListTile(
              leading: const Icon(Icons.library_music),
              title: Text(AppLocalizations.of(context)!.selectMusicLibraries),
              subtitle: ref.watch(finampSettingsProvider.isOffline)
                  ? Text(AppLocalizations.of(context)!.notAvailableInOfflineMode)
                  : null,
              enabled: !ref.watch(finampSettingsProvider.isOffline),
              onTap: () => Navigator.of(context).pushNamed(ViewSelector.routeName),
            ),
            ListTile(
              leading: const Icon(Icons.compress),
              title: Text(AppLocalizations.of(context)!.transcoding),
              onTap: () => Navigator.of(context).pushNamed(TranscodingSettingsScreen.routeName),
            ),
            ListTile(
              leading: const Icon(TablerIcons.cast),
              title: Text(AppLocalizations.of(context)!.playbackReportingSettingsTitle),
              onTap: () => Navigator.of(context).pushNamed(PlaybackReportingSettingsScreen.routeName),
            ),
            ListTile(
              leading: const Icon(TablerIcons.radio),
              title: const Text("Radio"),
              subtitle: const Text("Internet stations from your server"),
              onTap: () => Navigator.of(context).pushNamed(RadioScreen.routeName),
            ),
            if (ClientCertificateInstaller.isSupported)
              ListTile(
                leading: Icon(TablerIcons.certificate),
                title: Text(AppLocalizations.of(context)!.clientCertificate),
                subtitle: Text(
                  ref.watch(finampSettingsProvider.clientCertificate) != null
                      ? AppLocalizations.of(context)!.clientCertificateInstalled
                      : AppLocalizations.of(context)!.clientCertificateUnavailable,
                ),
                onTap: () => showClientCertificateMenu(context: context),
              ),
          ],
        ],
      ),
    );
  }
}
