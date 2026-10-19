import 'dart:io';

import 'package:diapason/screens/analytics_settings_screen.dart';
import 'package:diapason/components/PlaybackReportingSettingsScreen/discord_rpc_icon_selector.dart';
import 'package:diapason/components/PlaybackReportingSettingsScreen/enabled_discord_rpc.dart';
import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/components/update_dialog.dart';
import 'package:diapason/services/updater_prefs.dart';
import 'package:diapason/components/finamp_icon.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/menus/client_certificate_authentication_menu.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/screens/accessibility_settings_screen.dart';
import 'package:diapason/screens/audio_service_settings_screen.dart';
import 'package:diapason/screens/downloads_settings_screen.dart';
import 'package:diapason/screens/equalizer_settings_screen.dart';
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
import 'package:diapason/screens/ytdlp_settings_screen.dart';
import 'package:diapason/screens/sources_settings_screen.dart';
import 'package:diapason/screens/storage_settings_screen.dart';
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

  bool get _hasJellyfinSource => GetIt.instance<BackendRegistry>().ofKind(MediaSourceKind.jellyfin).isNotEmpty;

  bool get _hasTranscodingSource =>
      GetIt.instance<BackendRegistry>().enabled.any((backend) => backend.capabilities.transcoding);

  // In-app updater (sideloaded Android + desktop). null while the pref loads.
  bool? _autoUpdateEnabled;

  // Android and desktop ship outside the stores, so they self-update from
  // GitHub releases. iOS goes through the App Store and has no updater.
  bool get _hasUpdater => Platform.isAndroid || isDesktop;

  @override
  void initState() {
    super.initState();
    if (_hasUpdater) {
      UpdaterPrefs.isAutoCheckEnabled().then((value) {
        if (mounted) setState(() => _autoUpdateEnabled = value);
      });
    }
  }

  final _searchController = TextEditingController();
  String _query = "";

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Opens a settings screen by route.
  VoidCallback _go(String route) =>
      () => Navigator.of(context).pushNamed(route);

  List<_Section> _sections(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final offline = ref.watch(finampSettingsProvider.isOffline);
    final clientCertInstalled = ref.watch(finampSettingsProvider.clientCertificate) != null;

    return [
      _Section("Library & sources", TablerIcons.library, [
        _Entry(
          icon: TablerIcons.library,
          title: "Sources",
          subtitle: "Jellyfin, Plex, Subsonic and local files",
          onTap: _go(SourcesSettingsScreen.routeName),
          keywords: ["server", "jellyfin", "plex", "subsonic", "navidrome", "login", "account"],
        ),
        _Entry(
          icon: TablerIcons.file_import,
          title: "Import music",
          subtitle: "From this device, or the desktop app",
          onTap: _go(ImportScreen.routeName),
          keywords: ["files", "folder", "add"],
        ),
        _Entry(
          icon: Icons.download,
          title: l10n.downloadSettings,
          subtitle: "Offline copies and where they're kept",
          onTap: _go(DownloadsSettingsScreen.routeName),
          keywords: ["offline", "storage", "location"],
        ),
        if (_hasJellyfinSource) ...[
          _Entry(
            icon: Icons.library_music,
            title: l10n.selectMusicLibraries,
            subtitle: offline ? l10n.notAvailableInOfflineMode : "Which Jellyfin libraries to show",
            enabled: !offline,
            onTap: _go(ViewSelector.routeName),
            keywords: ["jellyfin", "views"],
          ),
          _Entry(
            icon: TablerIcons.radio,
            title: "Radio",
            subtitle: "Internet stations from your server",
            onTap: _go(RadioScreen.routeName),
            keywords: ["stations", "jellyfin"],
          ),
          if (ClientCertificateInstaller.isSupported)
            _Entry(
              icon: TablerIcons.certificate,
              title: l10n.clientCertificate,
              subtitle: clientCertInstalled ? l10n.clientCertificateInstalled : l10n.clientCertificateUnavailable,
              onTap: () => showClientCertificateMenu(context: context),
              keywords: ["tls", "mtls", "security", "jellyfin"],
            ),
        ],
      ]),
      _Section("Online music", TablerIcons.world, [
        _Entry(
          icon: TablerIcons.brand_youtube,
          title: "YouTube (yt-dlp)",
          subtitle: "Search, playback and yt-dlp setup",
          onTap: _go(YtDlpSettingsScreen.routeName),
          keywords: ["youtube", "yt-dlp", "ytdlp", "deno", "cookies", "proxy", "shelf", "hits", "results"],
        ),
        _Entry(
          icon: TablerIcons.cloud_upload,
          title: "Uploader",
          subtitle: "Send tracks to your server's library",
          onTap: _go(UploaderSettingsScreen.routeName),
          keywords: ["server", "upload", "token", "pair", "wifi", "https", "tunnel"],
        ),
        _Entry(
          icon: TablerIcons.broadcast,
          title: "Scrobbling",
          subtitle: "Last.fm and ListenBrainz",
          onTap: _go(ScrobblingSettingsScreen.routeName),
          keywords: ["lastfm", "listenbrainz", "history", "discover"],
        ),
      ]),
      _Section("Playback", TablerIcons.player_play, [
        _Entry(
          icon: Icons.music_note,
          title: l10n.audioService,
          subtitle: "Buffering, background behaviour",
          onTap: _go(AudioServiceSettingsScreen.routeName),
          keywords: ["buffer", "background", "notification", "crossfade"],
        ),
        _Entry(
          icon: Icons.equalizer_rounded,
          title: l10n.volumeNormalizationSettingsTitle,
          subtitle: "Even out loudness between tracks",
          onTap: _go(VolumeNormalizationSettingsScreen.routeName),
          keywords: ["replaygain", "loudness", "gain"],
        ),
        _Entry(
          icon: Icons.graphic_eq,
          title: "Equalizer",
          subtitle: "Per-band gain and presets",
          onTap: _go(EqualizerSettingsScreen.routeName),
          keywords: ["eq", "bass", "treble"],
        ),
        if (_hasTranscodingSource)
          _Entry(
            icon: Icons.compress,
            title: l10n.transcoding,
            subtitle: "Bitrate and codec when streaming or downloading",
            onTap: _go(TranscodingSettingsScreen.routeName),
            keywords: ["bitrate", "codec", "quality", "mp3", "opus"],
          ),
        if (_hasJellyfinSource)
          _Entry(
            icon: TablerIcons.cast,
            title: l10n.playbackReportingSettingsTitle,
            subtitle: "Tell Jellyfin what you play",
            onTap: _go(PlaybackReportingSettingsScreen.routeName),
            keywords: ["jellyfin", "history", "progress"],
          ),
        if (!isDesktop)
          _Entry(
            icon: TablerIcons.cast,
            title: "Cast",
            subtitle: "Send playback to a Chromecast",
            onTap: _go(CastScreen.routeName),
            keywords: ["chromecast", "tv"],
          ),
        if (isDesktop) ...[
          _Entry(
            title: "Discord Rich Presence",
            keywords: ["discord", "rpc", "presence", "activity", "status"],
            custom: (_) => const EnabledDiscordRpc(),
          ),
          _Entry(
            title: "Rich Presence icon",
            keywords: ["discord", "rpc", "presence", "icon"],
            custom: (_) => const DiscordRpcIconSelector(),
          ),
        ],
        _Entry(
          icon: TablerIcons.device_speaker,
          title: "Diapason Connect",
          subtitle: "Control another Diapason device",
          onTap: _go(ConnectScreen.routeName),
          keywords: ["remote", "devices", "transfer"],
        ),
      ]),
      _Section("Appearance & home", TablerIcons.palette, [
        _Entry(
          icon: Icons.widgets,
          title: l10n.layoutAndTheme,
          subtitle: "Theme, player, lists and tabs",
          onTap: _go(LayoutSettingsScreen.routeName),
          keywords: ["dark", "amoled", "colour", "color", "grid", "album", "artist", "lyrics", "tabs"],
        ),
        _Entry(
          icon: TablerIcons.home,
          title: l10n.homeScreenSettingsTitle,
          subtitle: "Sections on the home screen",
          onTap: _go(HomeScreenSettingsScreen.routeName),
        ),
        _Entry(
          icon: TablerIcons.pin,
          title: "Pins & searches",
          subtitle: "What's on your home screen and widget",
          onTap: _go(ShortcutsScreen.routeName),
          keywords: ["shortcuts", "widget"],
        ),
        _Entry(
          icon: TablerIcons.wave_sine,
          title: "Visualizer",
          subtitle: "Spectrum curve behind the player screen",
          onTap: _go(VisualizerSettingsScreen.routeName),
          keywords: ["spectrum", "fft", "animation"],
        ),
        _Entry(custom: (_) => const WrappedTile(), title: "Wrapped", keywords: ["year", "stats", "recap"]),
        if (!isDesktop)
          _Entry(
            icon: TablerIcons.player_play,
            title: "iPod Classic mode",
            subtitle: "Replaces the app with a click-wheel iPod",
            onTap: () {
              FinampSetters.setInterfaceMode(InterfaceMode.ipod.name);
              Navigator.of(context).pushNamed(IpodShell.routeName);
            },
            keywords: ["click wheel", "retro"],
          ),
      ]),
      _Section("Behaviour", TablerIcons.adjustments, [
        _Entry(
          icon: Icons.gesture,
          title: l10n.interactions,
          subtitle: "Swipes, haptics and screen behaviour",
          onTap: _go(InteractionSettingsScreen.routeName),
          keywords: ["swipe", "gesture", "vibration", "screen on"],
        ),
        _Entry(
          icon: Icons.wifi,
          title: l10n.networkSettingsTitle,
          subtitle: "Offline mode and automatic switching",
          onTap: _go(NetworkSettingsScreen.routeName),
          keywords: ["offline", "wifi", "mobile data", "local address"],
        ),
        _Entry(
          icon: TablerIcons.accessible,
          title: l10n.accessibility,
          subtitle: "Reduce motion, larger controls",
          onTap: _go(AccessibilitySettingsScreen.routeName),
        ),
        _Entry(
          icon: Icons.language,
          title: l10n.language,
          subtitle: ref.watch(finampSettingsProvider.locale)?.nativeDisplayLanguage ?? l10n.system,
          onTap: _go(LanguageSelectionScreen.routeName),
          keywords: ["locale", "translation"],
        ),
      ]),
      _Section("Storage & diagnostics", TablerIcons.database, [
        _Entry(
          icon: TablerIcons.database,
          title: "Storage & logs",
          subtitle: "Cache sizes, clean-up and log detail",
          onTap: _go(StorageSettingsScreen.routeName),
          keywords: ["cache", "clear", "disk", "space", "logs", "debug", "bug", "verbose"],
        ),
        _Entry(
          icon: TablerIcons.chart_bar,
          title: "Analytics & bug reports",
          subtitle: "Optional, anonymous, off by default",
          onTap: _go(AnalyticsSettingsScreen.routeName),
          keywords: ["privacy", "telemetry", "aptabase", "crash", "usage", "statistics"],
        ),
        _Entry(
          icon: TablerIcons.player_track_next,
          title: "Stream cache",
          subtitle: "Keep streamed tracks on disk",
          onTap: _go(CacheSettingsScreen.routeName),
          keywords: ["cache", "size", "limit"],
        ),
      ]),
      if (_hasUpdater)
        _Section("App updates", TablerIcons.refresh, [
          // Android and desktop aren't distributed through the stores, so offer
          // in-app updates straight from GitHub releases.
          _Entry(
            title: "Check for updates automatically",
            keywords: ["update", "github", "release", "version"],
            custom: (_) => SwitchListTile(
              secondary: const Icon(TablerIcons.refresh),
              title: const Text("Check for updates automatically"),
              subtitle: const Text("Look for a newer version on GitHub when the app starts"),
              value: _autoUpdateEnabled ?? true,
              onChanged: _autoUpdateEnabled == null
                  ? null
                  : (value) async {
                      setState(() => _autoUpdateEnabled = value);
                      await UpdaterPrefs.setAutoCheckEnabled(value);
                    },
            ),
          ),
          _Entry(
            icon: TablerIcons.download,
            title: "Check for updates now",
            subtitle: Platform.isAndroid
                ? "Download and install the latest release\nLong-press to reinstall the current version"
                : "Download the latest release from GitHub\nLong-press to reinstall the current version",
            keywords: ["update", "github", "reinstall"],
            custom: (_) => ListTile(
              leading: const Icon(TablerIcons.download),
              title: const Text("Check for updates now"),
              subtitle: Text(
                Platform.isAndroid
                    ? "Download and install the latest release\nLong-press to reinstall the current version"
                    : "Download the latest release from GitHub\nLong-press to reinstall the current version",
              ),
              isThreeLine: true,
              onTap: () => checkForUpdatesInteractive(context, silentIfUpToDate: false),
              onLongPress: () => checkForUpdatesInteractive(context, silentIfUpToDate: false, reinstall: true),
            ),
          ),
        ]),
    ].where((section) => section.entries.isNotEmpty).toList();
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: TextField(
      controller: _searchController,
      onChanged: (value) => setState(() => _query = value),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: "Search settings",
        prefixIcon: const Icon(TablerIcons.search),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(TablerIcons.x),
                tooltip: "Clear",
                onPressed: () {
                  _searchController.clear();
                  setState(() => _query = "");
                },
              ),
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(vertical: 0),
      ),
    ),
  );

  Widget _sectionCard(BuildContext context, _Section section, List<_Entry> entries) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 8),
          child: Row(
            children: [
              Icon(section.icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                section.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          elevation: 0,
          color: theme.colorScheme.surfaceContainerHigh,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Column(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.4)),
                entries[i].build(context),
              ],
            ],
          ),
        ),
      ],
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
                          const TextSpan(
                            text: "About this project",
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const TextSpan(text: '\n'),
                          const TextSpan(
                            text:
                                "Diapason started as a fork of Finamp, the open-source Jellyfin music player, "
                                "but it has since diverged and is now an independent project with its own "
                                "roadmap and architecture: several music sources (Jellyfin, Plex, Subsonic, local "
                                "files), YouTube through yt-dlp, an uploader for your server's library, and "
                                "desktop apps.\n\n"
                                "It is not affiliated with, endorsed by or supported by the Finamp project, so "
                                "please report issues to Diapason rather than to Finamp. Thanks to Finamp's "
                                "contributors for the foundation it was built on.",
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
      body: Builder(
        builder: (context) {
          final query = _query.trim().toLowerCase();
          final sections = _sections(context);
          final visible = <(_Section, List<_Entry>)>[];
          for (final section in sections) {
            // A section whose own name matches shows everything in it.
            final all = query.isEmpty || section.title.toLowerCase().contains(query);
            final entries = all ? section.entries : section.entries.where((e) => e.matches(query)).toList();
            if (entries.isNotEmpty) visible.add((section, entries));
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 200.0),
            children: [
              _searchField(),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(48),
                  child: Text(
                    "No settings match “$_query”.",
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              for (final (section, entries) in visible) _sectionCard(context, section, entries),
            ],
          );
        },
      ),
    );
  }
}

class _Section {
  const _Section(this.title, this.icon, this.entries);

  final String title;
  final IconData icon;
  final List<_Entry> entries;
}

/// One row of the settings home. Either a plain navigation tile or a [custom] widget.
class _Entry {
  const _Entry({
    required this.title,
    this.icon,
    this.subtitle,
    this.onTap,
    this.custom,
    this.keywords = const [],
    this.enabled = true,
  });

  final String title;
  final IconData? icon;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget Function(BuildContext)? custom;
  final List<String> keywords;
  final bool enabled;

  /// Every word the user typed must appear in the title, subtitle or keywords.
  bool matches(String query) {
    final haystack = "$title ${subtitle ?? ""} ${keywords.join(" ")}".toLowerCase();
    return query.split(RegExp(r"\s+")).every(haystack.contains);
  }

  Widget build(BuildContext context) =>
      custom?.call(context) ??
      ListTile(
        leading: icon == null ? null : Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: const Icon(TablerIcons.chevron_right, size: 18),
        enabled: enabled,
        onTap: onTap,
      );
}
