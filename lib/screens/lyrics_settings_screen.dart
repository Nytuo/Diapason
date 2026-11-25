import 'package:diapason/components/SettingsScreen/finamp_settings_dropdown.dart';
import 'package:diapason/components/lyrics_source_chip.dart' show downloadJapaneseDictionary;
import 'package:diapason/services/lyrics/japanese_dictionary.dart';
import 'package:diapason/services/lyrics/lyrics_extras.dart';
import 'package:diapason/services/lyrics/lyrics_translation.dart';
import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../extensions/localizations.dart';
import '../models/finamp_models.dart';
import '../services/finamp_settings_helper.dart';

class LyricsSettingsScreen extends StatefulWidget {
  const LyricsSettingsScreen({super.key});
  static const routeName = "/settings/lyrics";
  @override
  State<LyricsSettingsScreen> createState() => _LyricsSettingsScreenState();
}

class _LyricsSettingsScreenState extends State<LyricsSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.lyricsScreen),
        leading: FinampAppBarBackButton(),
        actions: [
          FinampSettingsHelper.makeSettingsResetButtonWithDialog(context, FinampSettingsHelper.resetLyricsSettings),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: const [
          LyricsAppleStyleToggle(),
          ShowLyricsTimestampsToggle(),
          ShowLyricsScreenAlbumPreludeToggle(),
          LyricsAlignmentSelector(),
          LyricsFontSizeSelector(),
          WordSyncedLyricsToggle(),
          NeteaseLyricsToggle(),
          Divider(),
          LyricsFuriganaToggle(),
          LyricsRomajiToggle(),
          JapaneseDictionaryTile(),
          Divider(),
          LyricsTranslationSettings(),
        ],
      ),
    );
  }
}

class ShowLyricsTimestampsToggle extends ConsumerWidget {
  const ShowLyricsTimestampsToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      title: Text(AppLocalizations.of(context)!.showLyricsTimestampsTitle),
      subtitle: Text(AppLocalizations.of(context)!.showLyricsTimestampsSubtitle),
      value: ref.watch(finampSettingsProvider.showLyricsTimestamps),
      onChanged: FinampSetters.setShowLyricsTimestamps,
    );
  }
}

class WordSyncedLyricsToggle extends ConsumerWidget {
  const WordSyncedLyricsToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      title: const Text("Word-by-word lyrics"),
      subtitle: const Text(
        "When your server only has line lyrics, look for word-timed ones in the community AMLL lyrics database.",
      ),
      value: ref.watch(finampSettingsProvider.wordSyncedLyricsEnabled),
      onChanged: FinampSetters.setWordSyncedLyricsEnabled,
    );
  }
}

class NeteaseLyricsToggle extends ConsumerWidget {
  const NeteaseLyricsToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      title: const Text("Word-by-word lyrics from NetEase"),
      subtitle: const Text(
        "Covers far more songs. Sends the title and artist of what you play to NetEase Cloud Music (unofficial).",
      ),
      value: ref.watch(finampSettingsProvider.neteaseLyricsEnabled),
      onChanged: FinampSetters.setNeteaseLyricsEnabled,
    );
  }
}

class LyricsAlignmentSelector extends ConsumerWidget {
  const LyricsAlignmentSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(AppLocalizations.of(context)!.lyricsAlignmentTitle),
      subtitle: Column(
        spacing: 4.0,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context)!.lyricsAlignmentSubtitle),
          FinampSettingsDropdown<LyricsAlignment>(
            dropdownItems: LyricsAlignment.values
                .map(
                  (e) => DropdownMenuEntry<LyricsAlignment>(
                    value: e,
                    label: e.toLocalisedString(context.l10n),
                    leadingIcon: switch (e) {
                      LyricsAlignment.start => Icon(
                        Directionality.of(context) == TextDirection.rtl
                            ? TablerIcons.align_right
                            : TablerIcons.align_left,
                      ),
                      LyricsAlignment.center => const Icon(TablerIcons.align_center),
                      LyricsAlignment.end => Icon(
                        Directionality.of(context) == TextDirection.rtl
                            ? TablerIcons.align_left
                            : TablerIcons.align_right,
                      ),
                    },
                  ),
                )
                .toList(),
            selectedValue: ref.watch(finampSettingsProvider.lyricsAlignment),
            onSelected: FinampSetters.setLyricsAlignment.ifNonNull,
          ),
        ],
      ),
    );
  }
}

class LyricsFontSizeSelector extends ConsumerWidget {
  const LyricsFontSizeSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(AppLocalizations.of(context)!.lyricsFontSizeTitle),
      subtitle: Column(
        spacing: 4.0,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context)!.lyricsFontSizeSubtitle),
          FinampSettingsDropdown<LyricsFontSize>(
            dropdownItems: LyricsFontSize.values
                .map((e) => DropdownMenuEntry<LyricsFontSize>(value: e, label: e.toLocalisedString(context.l10n)))
                .toList(),
            selectedValue: ref.watch(finampSettingsProvider.lyricsFontSize),
            onSelected: FinampSetters.setLyricsFontSize.ifNonNull,
          ),
        ],
      ),
    );
  }
}

class ShowLyricsScreenAlbumPreludeToggle extends ConsumerWidget {
  const ShowLyricsScreenAlbumPreludeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      title: Text(AppLocalizations.of(context)!.showLyricsScreenAlbumPreludeTitle),
      subtitle: Text(AppLocalizations.of(context)!.showLyricsScreenAlbumPreludeSubtitle),
      value: ref.watch(finampSettingsProvider.showLyricsScreenAlbumPrelude),
      onChanged: FinampSetters.setShowLyricsScreenAlbumPrelude,
    );
  }
}

class LyricsAppleStyleToggle extends ConsumerWidget {
  const LyricsAppleStyleToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      title: Text(AppLocalizations.of(context)!.lyricsAppleStyleTitle),
      subtitle: Text(AppLocalizations.of(context)!.lyricsAppleStyleSubtitle),
      value: ref.watch(finampSettingsProvider.lyricsAppleStyle),
      onChanged: FinampSetters.setLyricsAppleStyle,
    );
  }
}

/// Turning furigana or romaji on also fetches the dictionary they need.
void _setJapanese(BuildContext context, bool value, void Function(bool) setter) {
  setter(value);
  final status = JapaneseDictionary.instance.state.value.status;
  if (value && (status == JapaneseDictionaryStatus.missing || status == JapaneseDictionaryStatus.failed)) {
    downloadJapaneseDictionary(context);
  }
}

class LyricsFuriganaToggle extends ConsumerWidget {
  const LyricsFuriganaToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      title: Text(AppLocalizations.of(context)!.lyricsFuriganaTitle),
      subtitle: Text(AppLocalizations.of(context)!.lyricsFuriganaSubtitle),
      value: ref.watch(finampSettingsProvider.lyricsFurigana),
      onChanged: (value) => _setJapanese(context, value, FinampSetters.setLyricsFurigana),
    );
  }
}

class LyricsRomajiToggle extends ConsumerWidget {
  const LyricsRomajiToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile.adaptive(
      title: Text(AppLocalizations.of(context)!.lyricsRomajiTitle),
      subtitle: Text(AppLocalizations.of(context)!.lyricsRomajiSubtitle),
      value: ref.watch(finampSettingsProvider.lyricsRomaji),
      onChanged: (value) => _setJapanese(context, value, FinampSetters.setLyricsRomaji),
    );
  }
}

class JapaneseDictionaryTile extends ConsumerWidget {
  const JapaneseDictionaryTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(japaneseDictionaryProvider);
    final size = JapaneseDictionary.sizeLabel;
    return ListTile(
      leading: const Icon(TablerIcons.language_hiragana),
      title: Text(l10n.lyricsDictionaryTitle),
      subtitle: switch (state.status) {
        JapaneseDictionaryStatus.unsupported => Text(l10n.lyricsDictionaryUnsupported),
        JapaneseDictionaryStatus.missing => Text(l10n.lyricsDictionaryMissing(size)),
        JapaneseDictionaryStatus.ready => Text(l10n.lyricsDictionaryReady(size)),
        JapaneseDictionaryStatus.failed => Text(l10n.lyricsDictionaryFailed(state.error ?? "")),
        JapaneseDictionaryStatus.downloading => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.lyricsDictionaryDownloading((state.progress * 100).round())),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: state.progress),
          ],
        ),
      },
      trailing: switch (state.status) {
        JapaneseDictionaryStatus.missing || JapaneseDictionaryStatus.failed => TextButton(
          onPressed: () => downloadJapaneseDictionary(context),
          child: Text(l10n.lyricsDictionaryDownload),
        ),
        JapaneseDictionaryStatus.ready => TextButton(
          onPressed: JapaneseDictionary.instance.delete,
          child: Text(l10n.lyricsDictionaryDelete),
        ),
        _ => null,
      },
    );
  }
}

/// The master switch, the service and its server/key, and the target language.
class LyricsTranslationSettings extends ConsumerStatefulWidget {
  const LyricsTranslationSettings({super.key});

  @override
  ConsumerState<LyricsTranslationSettings> createState() => _LyricsTranslationSettingsState();
}

class _LyricsTranslationSettingsState extends ConsumerState<LyricsTranslationSettings> {
  late final _url = TextEditingController(text: LyricsTranslationService.instance.config.url);
  late final _key = TextEditingController(text: LyricsTranslationService.instance.config.apiKey);

  /// Endonyms, so they read the same in every app language.
  static const _languages = {
    "en": "English",
    "fr": "Français",
    "de": "Deutsch",
    "es": "Español",
    "it": "Italiano",
    "pt": "Português",
    "nl": "Nederlands",
    "pl": "Polski",
    "sv": "Svenska",
    "da": "Dansk",
    "fi": "Suomi",
    "cs": "Čeština",
    "ro": "Română",
    "hu": "Magyar",
    "el": "Ελληνικά",
    "tr": "Türkçe",
    "uk": "Українська",
    "ru": "Русский",
    "ar": "العربية",
    "he": "עברית",
    "hi": "हिन्दी",
    "id": "Bahasa Indonesia",
    "ja": "日本語",
    "ko": "한국어",
    "zh": "中文（简体）",
    "zh-Hant": "中文（繁體）",
  };

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  void _save(LyricsTranslationConfig config) => LyricsTranslationService.instance.setConfig(config);

  void _saveFields() {
    final config = LyricsTranslationService.instance.config;
    final updated = config.copyWith(url: _url.text.trim(), apiKey: _key.text.trim());
    if (updated != config) _save(updated);
  }

  @override
  void deactivate() {
    _saveFields();
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = ref.watch(finampSettingsProvider.lyricsTranslationEnabled);
    final config = ref.watch(lyricsTranslationConfigProvider);
    final libre = config.provider == LyricsTranslationProvider.libreTranslate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile.adaptive(
          title: Text(l10n.lyricsTranslationTitle),
          subtitle: Text(l10n.lyricsTranslationSubtitle),
          value: enabled,
          onChanged: FinampSetters.setLyricsTranslationEnabled,
        ),
        if (enabled) ...[
          ListTile(
            title: Text(l10n.lyricsTranslationService),
            subtitle: FinampSettingsDropdown<LyricsTranslationProvider>(
              dropdownItems: [
                for (final provider in LyricsTranslationProvider.values)
                  DropdownMenuEntry(value: provider, label: provider.label),
              ],
              selectedValue: config.provider,
              onSelected: (provider) {
                if (provider != null) _save(config.copyWith(provider: provider));
              },
            ),
          ),
          if (libre)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.lyricsTranslationServerUrl,
                  hintText: "https://libretranslate.example.org",
                  border: const OutlineInputBorder(),
                ),
                // Saved when done typing, so half-typed addresses aren't tried.
                onSubmitted: (_) => _saveFields(),
                onTapOutside: (_) => _saveFields(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: libre ? l10n.lyricsTranslationApiKeyOptional : l10n.lyricsTranslationApiKey,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _saveFields(),
              onTapOutside: (_) => _saveFields(),
            ),
          ),
          if (!config.isUsable)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(l10n.lyricsTranslationNotSetUp, style: Theme.of(context).textTheme.bodySmall),
            ),
          ListTile(
            title: Text(l10n.lyricsTranslationTarget),
            subtitle: FinampSettingsDropdown<String>(
              dropdownItems: [
                DropdownMenuEntry(value: "", label: l10n.lyricsTranslationAppLanguage),
                for (final entry in _languages.entries) DropdownMenuEntry(value: entry.key, label: entry.value),
              ],
              selectedValue: _languages.containsKey(config.targetLanguage) ? config.targetLanguage : "",
              onSelected: (language) {
                if (language != null) _save(config.copyWith(targetLanguage: language));
              },
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton.icon(
                icon: const Icon(TablerIcons.trash),
                label: Text(l10n.lyricsTranslationClearCache),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await LyricsTranslationService.instance.clearCache();
                  messenger.showSnackBar(SnackBar(content: Text(l10n.lyricsTranslationCacheCleared)));
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}
